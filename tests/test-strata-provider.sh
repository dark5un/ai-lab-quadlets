#!/usr/bin/env bash
# Live smoke test: the strata provider extension inside the running vscode
# box must (1) discover the live strata model, (2) stream a chat answer,
# (3) emit a well-formed tool call. Runs extension.js against real strata
# using the serve-web bundled node binary and the on-target API key.
# Skips (exit 0) when the stack is not up; fails (exit 1) on regression.
set -euo pipefail

command -v podman >/dev/null || { echo "SKIP: no podman"; exit 0; }
podman ps -f name=systemd-vscode --format '{{.Names}}' | grep -q . || { echo "SKIP: systemd-vscode not running"; exit 0; }
podman ps -f name=systemd-strata --format '{{.Names}}' | grep -q . || { echo "SKIP: systemd-strata not running"; exit 0; }

CONF="${AI_LAB_CONF:-$HOME/.config/containers/config}"
ENVFILE="$CONF/vscode/service.env"
[ -f "$ENVFILE" ] || { echo "SKIP: $ENVFILE missing (run generate-secrets.sh)"; exit 0; }
KEY=$(grep '^STRATA_API_KEY=' "$ENVFILE" | cut -d= -f2-)
[ -n "$KEY" ] || { echo "SKIP: STRATA_API_KEY empty in $ENVFILE"; exit 0; }

OUT=$(podman exec -i -e STRATA_API_KEY="$KEY" systemd-vscode bash -s <<'EOS'
set -e
NODE=$(find ~/.vscode/cli/serve-web -maxdepth 2 -name node -type f | head -1)
[ -n "$NODE" ] || { echo "no serve-web node binary"; exit 1; }
EXT=$(ls -d ~/.vscode-server/extensions/dark5un.strata-provider-* 2>/dev/null | head -1)
[ -n "$EXT" ] || { echo "strata-provider extension not installed in server home"; exit 1; }
cat > /tmp/strata-provider-smoke.cjs <<'HARNESS'
"use strict";
const Module = require("module");
const orig = Module._load;
class TextPart{constructor(v){this.value=v}}
class ToolCallPart{constructor(c,n,i){this.callId=c;this.name=n;this.input=i}}
const vscode={
  LanguageModelTextPart:TextPart,LanguageModelToolCallPart:ToolCallPart,
  LanguageModelToolResultPart:class{},LanguageModelDataPart:class{},
  LanguageModelChatMessageRole:{User:1,Assistant:2},
  LanguageModelChatToolMode:{Auto:1,Required:2},
  workspace:{getConfiguration:()=>({get:(k,d)=>d})},
  lm:{registerLanguageModelChatProvider:(v,p)=>{global.__provider=p;global.__vendor=v;}}
};
Module._load=function(r,...a){ if(r==="vscode") return vscode; return orig.call(this,r,...a); };
require(process.env.EXT+"/extension.js").activate({subscriptions:[]});
const token={onCancellationRequested:()=>({dispose(){}})};
(async()=>{
  const p=global.__provider;
  const models=await p.provideLanguageModelChatInformation({silent:true},token);
  if(!models.length) throw new Error("no models discovered");
  const m=models[0];
  if(!(m.maxInputTokens>0&&m.maxOutputTokens>0)) throw new Error("bad token limits");
  let text="";
  await p.provideLanguageModelChatResponse(m,
    [{role:1,name:undefined,content:[new TextPart("Reply with exactly: STRATA-OK")]}],
    {toolMode:1},{report(pt){if(pt.value)text+=pt.value;}},token);
  if(!text.includes("STRATA")) throw new Error("chat text missing: "+text.slice(0,80));
  let called=null;
  // IQ3-class local models occasionally answer tool prompts in plain text;
  // retry before declaring a regression (transport+API correctness is what we test).
  for (let attempt = 0; attempt < 3 && !called; attempt++) {
    await p.provideLanguageModelChatResponse(m,
      [{role:1,name:undefined,content:[new TextPart("Call the calculator tool with expr 21*6.")] }],
      {toolMode:1,tools:[{name:"calculator",description:"Evaluate a math expression",inputSchema:{type:"object",properties:{expr:{type:"string"}},required:["expr"]}}]},
      {report(pt){if(pt instanceof ToolCallPart)called=pt;}},token);
  }
  if(!called) throw new Error("no tool call emitted after 3 attempts");
  console.log("PASS vendor="+global.__vendor+" model="+m.id+" ctx="+m.maxInputTokens+" text=ok tool="+called.name);
})().catch(e=>{console.error("FAIL: "+e.message);process.exit(1)});
HARNESS
EXT="$EXT" "$NODE" /tmp/strata-provider-smoke.cjs
EOS
)
echo "$OUT"
echo "$OUT" | grep -q '^PASS ' || { echo "strata-provider smoke test failed"; exit 1; }
echo "test-strata-provider: PASS"
