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
set noswapfile
highlight Comment ctermfg=green
highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/

" syntax highlighting for scons files
au BufRead,BufNewFile SConstruct set filetype=python
au BufRead,BufNewFile SConscript set filetype=python

" auto resize splits
autocmd VimResized * wincmd =
