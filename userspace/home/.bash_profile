export EDITOR='vim'
export VIMINIT='source $MYVIMRC'
export MYVIMRC="~/.vimrc"

source $HOME/.profile

# TODO: there's probably a better way to do this for only the main tmux session
[ -d "/data/openpilot" ] && cd /data/openpilot
