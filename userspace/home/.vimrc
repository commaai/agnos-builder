syntax on
set tabstop=2
set shiftwidth=2
set expandtab
set ai
set number
set hlsearch
set ruler
set mouse=
set viminfo=""
highlight Comment ctermfg=green
highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/

au BufRead,BufNewFile SConstruct set filetype=python
au BufRead,BufNewFile SConscript set filetype=python
