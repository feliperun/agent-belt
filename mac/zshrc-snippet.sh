# --- tmux helper (adicionado via claude code) ---
# tm nome  -> reata a sessao se existir, cria se nao existir
tm() { tmux new -A -s "${1:-main}"; }

# --- work: worktree isolado + tmux + claude autonomo (adicionado via claude code) ---
# work nome-da-tarefa  -> dentro de um repo git, cria um worktree irmao (fora do
# repo principal), uma sessao tmux e sobe o claude la dentro; reata se ja existir.
# A logica vive em ~/.local/bin/work-session, que o debian tambem chama via ssh.
work() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
  work-session "$1" "$repo_root"
}
