let s:t_number = type(0)
let s:running_writers = {}
let s:exiting = v:false

function! s:_vital_healthcheck() abort
  if (!has('nvim') && v:version >= 800) || has('nvim-0.2.0')
    return
  endif
  return 'This module requires Vim 8.0.0000 or Neovim 0.2.0'
endfunction

function! s:_vital_created(module) abort
  " Default updatetime
  let a:module.updatetime = 100

  " Subscribe VimLeave to cancel 'replace()' during VimLeave
  let sid = matchstr(
        \ get(function('s:_vital_created'), 'name'),
        \ '<SNR>\zs\d\+\ze'
        \)
  execute 'augroup vital_vim_buffer_writer_' . sid
  execute 'autocmd! *'
  execute 'autocmd VimLeave * let s:exiting = v:true'
  execute 'augroup END'
endfunction

function! s:_iconv(bufnr, content) abort
  let fileencoding = getbufvar(a:bufnr, '&fileencoding')
  if fileencoding ==# '' || fileencoding ==? &encoding || empty(a:content)
    return a:content
  endif
  let result = iconv(join(a:content, "\n"), fileencoding, &encoding)
  return empty(result) ? a:content : split(result, '\n', 1)
endfunction

if exists('*nvim_buf_set_lines')
  function! s:_replace(bufnr, start, end, replacement) abort
    try
      call nvim_buf_set_lines(a:bufnr, a:start, a:end, v:true, a:replacement)
    catch /^Vim(call):\%(E5555: API call: \)\?Index out of bounds/
      return 1
    endtry
  endfunction
else
  function! s:_replace(bufnr, start, end, replacement) abort
    if bufnr('%') == a:bufnr
      return s:_replace_local(a:start, a:end, a:replacement)
    elseif bufwinnr(a:bufnr) != -1
      return s:_replace_shown(a:bufnr, a:start, a:end, a:replacement)
    else
      return s:_replace_hidden(a:bufnr, a:start, a:end, a:replacement)
    endif
  endfunction

  " Used to replace content of current window
  function! s:_replace_local(start, end, replacement) abort
    " Calculate negative indices and validate
    let lnum = line('$')
    let s = a:start >= 0 ? a:start : lnum + 1 + a:start
    let e = a:end >= 0 ? a:end : lnum + 1 + a:end
    if s < 0 || s > lnum || e < 0 || e > lnum
      return 1
    endif
    " Save current cursor pos
    let cursor_saved = getcurpos()
    try
      " NOTE: append() affects jumplist so the following does not work
      " " Insert replacement to the index
      " let failed = append(s, a:replacement)
      " " Shrink lines between {start} and {end} (exclusive)
      " if !failed && e - s > 0
      "   let length = len(a:replacement)
      "   execute printf(
      "         \ 'silent keepjumps %d,%ddelete _',
      "         \ length + s + 1,
      "         \ length + e,
      "         \)
      " endif
      " NOTE: Use setline() instead
      let suffixes = getline(e + 1, '$')
      if s < lnum
        execute printf(
              \ 'silent keepjumps %d,$delete _',
              \ s + 1,
              \)
      endif
      return setline(s + 1, a:replacement + suffixes)
    finally
      call setpos('.', cursor_saved)
    endtry
  endfunction

  " Used to replace content of shown buffer (in current tabpage)
  function! s:_replace_shown(bufnr, start, end, replacement) abort
    let winnr_saved = winnr()
    execute printf('%dwincmd w', bufwinnr(a:bufnr))
    try
      return s:_replace_local(a:start, a:end, a:replacement)
    finally
      execute printf('%dwincmd w', winnr_saved)
    endtry
  endfunction

  " Used to replace content of hidden buffer
  function! s:_replace_hidden(bufnr, start, end, replacement) abort
    let bufnr_saved = bufnr('%')
    let bufhidden_saved = &l:bufhidden
    setlocal bufhidden=hide
    execute printf('keepjumps %dbuffer', a:bufnr)
    try
      return s:_replace_local(a:start, a:end, a:replacement)
    finally
      execute printf('keepjumps %dbuffer', bufnr_saved)
      let &l:bufhidden = bufhidden_saved
    endtry
  endfunction
endif


" Public method ------------------------------------------------------------
function! s:replace(expr, start, end, replacement) abort
  let bufnr = bufnr(a:expr)
  if v:dying || s:exiting || !bufexists(bufnr)
    return 1
  endif
  let data = s:_iconv(bufnr, a:replacement)
  let modifiable = getbufvar(bufnr, '&modifiable')
  let buflisted = getbufvar(bufnr, '&buflisted')
  let readonly = getbufvar(bufnr, '&readonly')
  try
    call setbufvar(bufnr, '&modifiable', 1)
    call setbufvar(bufnr, '&readonly', 0)
    return s:_replace(bufnr, a:start, a:end, data)
  finally
    call setbufvar(bufnr, '&modifiable', modifiable)
    call setbufvar(bufnr, '&buflisted', buflisted)
    call setbufvar(bufnr, '&readonly', readonly)
  endtry
endfunction

function! s:new(...) abort dict
  let options = a:0 ? a:1 : {}
  let options = extend({
        \ 'bufnr': bufnr('%'),
        \ 'updatetime': self.updatetime,
        \}, a:0 ? a:1 : {},
        \)
  let writer = extend(options, s:writer)
  let writer.__timer = v:null
  let writer.__running = 0
  let writer.__content = []
  return writer
endfunction


" Writer instance ----------------------------------------------------------
function! s:_writer_timer_callback(writer, ...) abort
  " Check environment if writer is available and kill forcedly if not
  if v:dying || s:exiting || !bufexists(a:writer.bufnr)
    call a:writer.kill()
    return
  endif
  " To improve UX, flush only when a target buffer is shown
  if bufwinnr(a:writer.bufnr) != -1
    call a:writer.flush()
  endif
  " Kill writer when writing has been completed
  if !a:writer.__running && empty(a:writer.__content)
    " Content may has an extra line at EOF (POSIX text) so remove it.
    if empty(getbufline(a:writer.bufnr, '$')[-1])
      call s:replace(a:writer.bufnr, -2, -1, [])
    endif
    call a:writer.kill()
  endif
endfunction

function! s:_writer_start() abort dict
  if self.__timer isnot# v:null
    return 1
  endif
  if has_key(s:running_writers, self.bufnr)
    call s:running_writers[self.bufnr].kill()
  endif
  let self.__running = 1
  let self.__timer = timer_start(
        \ self.updatetime,
        \ function('s:_writer_timer_callback', [self]),
        \ { 'repeat': -1 },
        \)
  let s:running_writers[self.bufnr] = self
  if has_key(self, 'on_start')
    call self.on_start()
  endif
endfunction

function! s:_writer_stop() abort dict
  let self.__running = 0
endfunction

function! s:_writer_kill() abort dict
  if self.__timer is# v:null
    return 1
  endif
  silent! call timer_stop(self.__timer)
  silent! unlet! s:running_writers[self.bufnr]
  let self.__running = 0
  let self.__timer = v:null
  if has_key(self, 'on_exit')
    call self.on_exit()
  endif
endfunction

function! s:_writer_write(content) abort dict
  if empty(self.__content)
    let self.__content = ['']
  endif
  let self.__content[-1] .= a:content[0]
  call extend(self.__content, a:content[1:])
endfunction

function! s:_writer_flush(...) abort dict
  if empty(self.__content)
    return 1
  endif
  try
    let content = remove(self.__content, 0, -1)
    let replacement = has_key(self, 'on_read')
          \ ? self.on_read(content)
          \ : deepcopy(content)
    let replacement[0] = getbufline(self.bufnr, '$')[-1] . replacement[0]
    call s:replace(self.bufnr, -2, -1, replacement)
  catch /^Vim\%((\a\+)\)\=:E523/
    " Vim raise 'E523: Not allowed here' when called in 'BufReadCmd'
    " so rollback the operation
    call extend(self.__content, content, 0)
  endtry
endfunction

let s:writer = {
      \ 'start': function('s:_writer_start'),
      \ 'stop': function('s:_writer_stop'),
      \ 'kill': function('s:_writer_kill'),
      \ 'write': function('s:_writer_write'),
      \ 'flush': function('s:_writer_flush'),
      \}
