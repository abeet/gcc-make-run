###
# a remake of kriscross07/atom-gpp-compiler with extended features
# https://github.com/kriscross07/atom-gpp-compiler
# https://atom.io/packages/gpp-compiler
###

GccMakeRunView = require './gcc-make-run-view'
{CompositeDisposable} = require 'atom'
{parse, join} = require 'path'
{exec, execSync} = require 'child_process'
{statSync} = require 'fs'
{_extend} = require 'util'

module.exports = GccMakeRun =
  config:
    'C':
      title: 'gcc Compiler'
      type: 'string'
      default: 'gcc'
      order: 1
      description: 'Compiler for C, in full path or command name (make sure it is in your $PATH)'
    'C++':
      title: 'g++ Compiler'
      type: 'string'
      default: 'g++'
      order: 2
      description: 'Compiler for C++, in full path or command name (make sure it is in your $PATH)'
    'make':
      title: 'make Utility'
      type: 'string'
      default: 'make'
      order: 3
      description: 'The make utility used for compilation, in full path or command name (make sure it is in your $PATH)'
    'uncondBuild':
      title: 'Unconditional Build'
      type: 'boolean'
      default: false
      order: 4
      description: 'Compile even if executable is up to date'
    'cflags':
      title: 'Compiler Flags'
      type: 'string'
      default: ''
      order: 5
      description: 'Flags for compiler, eg: -Wall'
    'ldlibs':
      title: 'Link Libraries'
      type: 'string'
      default: ''
      order: 6
      description: 'Libraries for linking, eg: -lm'
    'args':
      title: 'Run Arguments'
      type: 'string'
      default: ''
      order: 7
      description: 'Arguments for executing, eg: 1 "2 3"'
  gccMakeRunView: null
  onceRebuild: false

  ###
  # package setup
  ###
  activate: (state) ->
    @gccMakeRunView = new GccMakeRunView(@)
    atom.commands.add 'atom-workspace', 'gcc-make-run:compile-run': => @compile()
    atom.commands.add '.tree-view .file > .name', 'gcc-make-run:make-run': (e) => @make(e.target.getAttribute('data-path'))

  deactivate: ->
    @gccMakeRunView.cancel()

  serialize: ->
    gccMakeRunViewState: @gccMakeRunView.serialize()

  ###
  # compile and make run
  ###
  compile: () ->
    # get editor
    editor = atom.workspace.getActiveTextEditor()
    return unless editor?

    # save file
    srcPath = editor.getPath()
    if !srcPath
      atom.notifications.addError('gcc-make-run: File Not Saved', { detail: 'Temporary files must be saved first' })
      return
    editor.save() if editor.isModified()

    # get grammar
    grammar = editor.getGrammar().name
    switch grammar
      when 'C', 'C++' then
        # do nothing
      when 'Makefile'
        @make(srcPath)
        return
      else
        atom.notifications.addError('gcc-make-run: Grammar Not Supported', { detail: 'Only C, C++ and Makefile are supported' })
        return

    # get config
    info = parse(editor.getPath())
    info.useMake = false;
    info.exe = info.name + if process.platform == 'win32' then '.exe' else ''
    compiler = atom.config.get("gcc-make-run.#{grammar}")
    cflags = atom.config.get('gcc-make-run.cflags')
    ldlibs = atom.config.get('gcc-make-run.ldlibs')

    # check if update needed before compile
    if !@shouldUncondBuild() && @isExeUpToDate(info)
        @run(info)
    else
      cmd = "\"#{compiler}\" #{cflags} \"#{info.base}\" -o \"#{info.name}\" #{ldlibs}"
      atom.notifications.addInfo('gcc-make-run: Running Command...', { detail: cmd })
      exec(cmd , { cwd: info.dir }, @onBuildFinished.bind(@, info))

  make: (srcPath) ->
    # get config
    info = parse(srcPath)
    info.useMake = true;
    mk = atom.config.get('gcc-make-run.make')
    mkFlags = if @shouldUncondBuild() then '-B' else ''

    # make
    cmd = "\"#{mk}\" #{mkFlags} -f \"#{info.base}\""
    atom.notifications.addInfo('gcc-make-run: Running Command...', { detail: cmd })
    exec(cmd, { cwd: info.dir }, @onBuildFinished.bind(@, info))

  onBuildFinished: (info, error, stdout, stderr) ->
    # notifications about compilation status
    hasCompiled = (stdout?.indexOf('up to date') < 0 && stdout?.indexOf('to be done') < 0) || !stdout?
    atom.notifications[if error then 'addError' else 'addWarning']("gcc-make-run: Compile #{if error then 'Error' else 'Warning'}", { detail: stderr, dismissable: true }) if stderr
    atom.notifications[if hasCompiled then 'addInfo' else 'addSuccess']('gcc-make-run: Compiler Output', { detail: stdout }) if stdout

    # continue only if no error
    return if error
    atom.notifications.addSuccess('gcc-make-run: Build Success') if hasCompiled
    @run(info)

  run: (info) ->
    # build the run cmd
    return unless @checkMakeRunTarget(info)
    return unless @buildRunCmd(info)

    # run the cmd
    console.log info.cmd
    exec(info.cmd, { cwd: info.dir, env: info.env }, @onRunFinished.bind(@))

  onRunFinished: (error, stdout, stderr) ->
    # debug use
    if error
      atom.notifications.addError('gcc-make-run: Run Command Failed', { detail: stderr })

  ###
  # helper functions
  ###
  isExeUpToDate: (info) ->
    # check src and exe modified time
    srcTime = statSync(join(info.dir, info.base)).mtime.getTime()
    try
      exeTime = statSync(join(info.dir, info.exe)).mtime.getTime()
    catch error
      exeTime = 0

    if srcTime < exeTime
      atom.notifications.addSuccess("gcc-make-run: Output Up To Date", { detail: "'#{info.exe}' is up to date" })
      return true
    return false

  checkMakeRunTarget: (info) ->
    # return if not using Makefile
    return true if !info.useMake

    mk = atom.config.get("gcc-make-run.make")
    info.exe = undefined

    # try make run to get the target
    try
      info.exe = execSync("\"#{mk}\" -nf \"#{info.base}\" run", { cwd: info.dir, stdio: [], encoding: 'utf8' }).match(/[^#\r\n]+/g)[0]
      if !info.exe || info.exe.indexOf('to be done') >= 0 then throw Error()
      if process.platform == 'win32' && info.exe.indexOf('.exe') != -1 then info.exe += '.exe'
      return true
    catch error
      # cannot get run target
      atom.notifications.addError(
        "gcc-make-run: Cannot find 'run' target",
        {
          detail: """
            Target 'run' is not specified in #{info.base}
            Example 'run' target:
            run:
              excutable $(ARGS)
          """,
          dismissable: true
        }
      )
      return false

  shouldUncondBuild: ->
    ret = @onceRebuild || atom.config.get('gcc-make-run.uncondBuild')
    @onceRebuild = false
    return ret

  buildRunCmd: (info) ->
    # get config
    mk = atom.config.get('gcc-make-run.make')
    info.env = _extend({ ARGS: atom.config.get('gcc-make-run.args') }, process.env)

    if info.useMake
      switch process.platform
        when 'win32' then info.cmd = "start \"#{info.exe}\" cmd /c \"\"#{mk}\" -sf \"#{info.base}\" run && pause || pause\""
        # TODO: when 'linux' then
        # TODO: when 'darwin' then
    else
      # normal run
      switch process.platform
        when 'win32' then info.cmd = "start \"#{info.exe}\" cmd /c \"\"#{info.exe}\" #{info.env.ARGS} && pause || pause\""
        # TODO: when 'linux' then
        # TODO: when 'darwin' then

    # check if cmd is built
    return true if info.cmd?
    atom.notifications.addError('gcc-make-run: Cannot Execute Output', { detail: 'Execution after compiling is not supported on your OS' })
    return false
