{CompositeDisposable,Disposable,BufferedProcess,Selection,File} = require 'atom'
path = require 'path'
util = require './util'
{buildGoDeclarationCommandArgs,buildEmitPchCommandArgs} = require './clang-args-builder'
LocationSelectList = require './location-select-view.coffee'

ClangProvider = null
defaultPrecompiled = require './defaultPrecompiled'

module.exports =
  config:
    clangCommand:
      type: 'string'
      default: 'clang'
    includePaths:
      type: 'array'
      default: ['.']
      items:
        type: 'string'
    pchFilePrefix:
      type: 'string'
      default: '.stdafx'
    ignoreClangErrors:
      type: 'boolean'
      default: true
    includeDocumentation:
      type: 'boolean'
      default: true
    includeSystemHeadersDocumentation:
      type: 'boolean'
      default: false
      description:
        "**WARNING**: if there are any PCHs compiled without this option,"+
        "you will have to delete them and generate them again"
    includeNonDoxygenCommentsAsDocumentation:
      type: 'boolean'
      default: false
    "std c++":
      type: 'string'
      default: "c++11"
    "std c":
      type: 'string'
      default: "c99"
    "preCompiledHeaders c++":
      type: 'array'
      default: defaultPrecompiled.cpp
      item:
        type: 'string'
    "preCompiledHeaders c":
      type: 'array'
      default: defaultPrecompiled.c
      items:
        type: 'string'
    "preCompiledHeaders objective-c":
      type: 'array'
      default: defaultPrecompiled.objc
      items:
        type: 'string'
    "preCompiledHeaders objective-c++":
      type: 'array'
      default: defaultPrecompiled.objcpp
      items:
        type: 'string'

  deactivationDisposables: null

  activate: (state) ->
    @deactivationDisposables = new CompositeDisposable
    @deactivationDisposables.add atom.commands.add 'atom-text-editor:not([mini])',
      'autocomplete-clang:emit-pch': =>
        @emitPch atom.workspace.getActiveTextEditor()
    @deactivationDisposables.add atom.commands.add 'atom-text-editor:not([mini])',
      'autocomplete-clang:go-declaration': (e)=>
        @goDeclaration atom.workspace.getActiveTextEditor(),e

  goDeclaration: (editor,e)->
    lang = util.getFirstCursorSourceScopeLang editor
    unless lang
      e.abortKeyBinding()
      return
    new Promise (resolve) =>
      command = atom.config.get "autocomplete-clang.clangCommand"
      editor.selectWordsContainingCursors()
      term = editor.getSelectedText()
      args = buildGoDeclarationCommandArgs editor,lang,term
      options = cwd: path.dirname(editor.getPath())
      allOutput = []
      stdout = (output) -> allOutput.push(output)
      stderr = (output) -> console.log output
      exit = (code) =>
        resolve(@handleGoDeclarationResult(editor, {output:allOutput.join("\n"),term:term}, code))
      bufferedProcess = new BufferedProcess({command, args, options, stdout, stderr, exit})
      bufferedProcess.process.stdin.setEncoding = 'utf-8'
      bufferedProcess.process.stdin.write(editor.getText())
      bufferedProcess.process.stdin.end()

  emitPch: (editor)->
    lang = util.getFirstCursorSourceScopeLang editor
    unless lang
      atom.notifications.addError "autocomplete-clang:emit-pch\nError: Incompatible Language"
      return
    new Promise (resolve) =>
      headers = atom.config.get "autocomplete-clang.preCompiledHeaders #{lang}"
      headersInput = ("#include <#{h}>" for h in headers).join "\n"
      command = atom.config.get "autocomplete-clang.clangCommand"
      args = buildEmitPchCommandArgs editor,lang
      options = cwd: path.dirname editor.getPath()
      stdout = (output) -> console.log "-emit-pch out:\n"+output.toString()
      stderr = (output) -> console.log "-emit-pch err:\n"+output.toString()
      exit = (code) => resolve(@handleEmitPchResult code)
      bufferedProcess = new BufferedProcess({command, args, options, stdout, stderr, exit})
      bufferedProcess.process.stdin.setEncoding = 'utf-8'
      bufferedProcess.process.stdin.write(headersInput)
      bufferedProcess.process.stdin.end()

  handleGoDeclarationResult: (editor, result, returnCode)->
    if returnCode is not 0
      return unless atom.config.get "autocomplete-clang.ignoreClangErrors"
    places = @parseAstDump result['output'], result['term']
    if places.length is 1
      @goToLocation editor, places.pop()
    else if places.length > 1
      list = new LocationSelectList(editor, @goToLocation)
      list.setItems(places)

  goToLocation: (editor, [file,line,col]) ->
    if file is '<stdin>'
      return editor.setCursorBufferPosition [line-1,col-1]
    file = path.join editor.getDirectoryPath(), file if file.startsWith(".")
    f = new File file
    f.exists().then (result) ->
      atom.workspace.open file, {initialLine:line-1, initialColumn:col-1} if result

  parseAstDump: (aststring, term)->
    candidates = aststring.split '\n\n'
    places = []
    for candidate in candidates
      match = candidate.match ///^Dumping\s(?:[A-Za-z_]*::)*?#{term}:///
      if match isnt null
        lines = candidate.split '\n'
        continue if lines.length < 2
        declTerms = lines[1].split ' '
        [_,_,declRangeStr,_,posStr,...] = declTerms
        [_,_,_,_,declRangeStr,_,posStr,...] = declTerms if declRangeStr is "prev"
        [_,file,line,col] = declRangeStr.match /<(.*):([0-9]+):([0-9]+),/
        positions = posStr.match /(line|col):([0-9]+)(?::([0-9]+))?/
        if positions
          if positions[1] is 'line'
            [line,col] = [positions[2], positions[3]]
          else
            col = positions[2]
        places.push [file,(Number line),(Number col)]
    return places

  handleEmitPchResult: (code)->
    unless code
      atom.notifications.addSuccess "Emiting precompiled header has successfully finished"
      return
    atom.notifications.addError "Emiting precompiled header exit with #{code}\n"+
      "See console for detailed error message"

  deactivate: ->
    @deactivationDisposables.dispose()

  provide: ->
    ClangProvider ?= require('./clang-provider')
    new ClangProvider()
