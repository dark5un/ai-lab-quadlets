# jupyter_server_config.py - installed to config/notebook/ (mode 600) and
# bind-mounted ro into the notebook-state volume's .jupyter dir.
# docker-stacks' start-notebook.py mints its own random token and shadows
# --ServerApp.token_file (verified live 2026-11-05); pin the stack token
# file explicitly instead. Not secret itself - it only reads the 600 file.
with open("/run/jupyter/token") as _f:
    c.ServerApp.token = _f.read().strip()
