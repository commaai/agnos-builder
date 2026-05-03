# ~/.bashrc: read by interactive non-login shells.

case $- in
  *i*) ;;
  *) return ;;
esac

PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '

alias ls='ls --color=auto'

if [ -f "$HOME/.bash_aliases" ]; then
  . "$HOME/.bash_aliases"
fi
