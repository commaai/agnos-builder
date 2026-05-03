export EDITOR='vim'
export VIMINIT='source $MYVIMRC'
export MYVIMRC="~/.vimrc"

if [ -f "$HOME/.profile" ]; then
  source "$HOME/.profile"
fi

if [ -d "/data/openpilot" ] && [ "$(tmux display-message -p '#{session_name}' 2>/dev/null)" = "comma" ] ; then
  cd /data/openpilot
fi
