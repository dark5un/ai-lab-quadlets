# ujust Integration

This repo ships an `ai-lab.just` file that defines `install`, `uninstall`, and
`status` recipes for the AI Lab Quadlet services. There are three ways to use
it, ranging from zero-intrusion to permanent system registration.

---

## Approach 3: Direct invocation (recommended — least intrusive)

No setup needed. Run recipes by pointing `just` at the file:

```bash
# Clone the repo
git clone https://github.com/dark5un/ai-lab-quadlets.git
cd ai-lab-quadlets

# Install all services
just -f ai-lab.just install

# Check status
just -f ai-lab.just status

# Uninstall everything
just -f ai-lab.just uninstall
```

**Pros:**
- Zero system modifications
- Nothing to undo on uninstall
- Works on any distro, not just uBlue
- Works in a distrobox/container too

**Cons:**
- Requires the repo to be present and the `-f` flag
- Not discoverable via `ujust --list`
- Must remember the path

---

## Approach 2: User-level global justfile (immutable-safe)

Register the `ai-lab.just` as a permanent recipe in your user justfile.
`ujust` still works because the user justfile can import the system recipes
and also import the AI Lab recipes.

### Step 1: Create or edit ~/.config/just/justfile

```bash
mkdir -p ~/.config/just
```

If you don't have a custom justfile yet, create one that imports the system
recipes and the AI Lab recipes:

```just
# ~/.config/just/justfile
# Import system ujust recipes (keep your ujust commands working)
import "/usr/share/ublue-os/just/00-entry.just"

# Import AI Lab Quadlet recipes
import "~/ai-lab-quadlets/ai-lab.just"
```

If you already have a `~/.config/just/justfile`, just add the import line.

### Step 2: Set up the alias

Add this to your `~/.bashrc` or `~/.zshrc`:

```bash
alias ujust='just --justfile ~/.config/just/justfile'
```

Then reload: `source ~/.bashrc`

### Step 3: Use it

```bash
ujust install-ai-lab
ujust uninstall-ai-lab
ujust status-ai-lab
```

Your original ujust commands (`update`, `toggle-devmode`, etc.) still work
because they're imported from the system justfile.

**Pros:**
- Writes nothing to `/usr/` — survives OS rebases and updates
- `install-ai-lab` shows in `ujust --list` alongside system commands
- Works on any uBlue image (Bluefin, Aurora, Bazzite)
- Easy to remove: delete `~/.config/just/justfile` and remove the alias

**Cons:**
- Requires the alias in shell config
- The repo must stay at the expected path
- Shell alias means other utilities calling `ujust` directly won't see it

---

## Approach 1: System-level 60-custom.just (permanent on image)

Copy the `ai-lab.just` into the ujust recipe directory. This makes the recipes
available natively via `ujust` with no alias, no imports, no shell config.

```bash
sudo cp ai-lab.just /usr/share/ublue-os/just/60-custom.just
```

Then `ujust install-ai-lab`, `ujust uninstall-ai-lab`, and `ujust status-ai-lab`
work immediately — just like any built-in ujust command.

**Pros:**
- Zero-config — no alias, no shell file edits
- Recipes appear in `ujust --list` automatically
- Works even from scripts that call `ujust` directly

**Cons:**
- Requires `sudo` to write to `/usr/`
- **Lost on image updates** — each `rpm-ostree update` / `bootc upgrade`
  replaces the immutable root, wiping the file
- Must be re-copied after every rebase (or layered via a custom Containerfile)
- Writes to the immutable OSTree root (layering, not permanent)

### Making it permanent (image build)

If you build a custom Bluefin image, add the file at image build time via a
Containerfile:

```dockerfile
COPY ai-lab.just /usr/share/ublue-os/just/60-custom.just
```

Or via BlueBuild's `justfiles` module:

```yaml
modules:
  - type: justfiles
    include:
      - ai-lab.just
```

Then the recipe is part of your image, survives updates, and works on every boot.

---

## Recipe reference

| Recipe | Description |
|---|---|
| `install-ai-lab` | Detect GPUs, generate secrets, build images, deploy quadlets, enable services |
| `uninstall-ai-lab` | Stop and disable all services, remove quadlet files, preserve data volumes |
| `status-ai-lab` | Show which AI Lab services are active, enabled, or not installed |

All recipes run via the scripts in the `scripts/` directory. The `ai-lab.just`
file is a thin wrapper that calls them in the right order with the right paths.