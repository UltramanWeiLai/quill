#= require underscore
#= require rangy-core
#= require diff_match_patch
#= require eventemitter2
#= require jetsync
#= require tandem/document
#= require tandem/selection

class TandemEditor extends EventEmitter2
  @editors: []

  events: 
    API_TEXT_CHANGE       : 'api-text-change'
    USER_SELECTION_CHANGE : 'user-selection-change'
    USER_TEXT_CHANGE      : 'user-text-change'

  options:
    POLL_INTERVAL: 500

  constructor: (@container) ->
    @container = document.getElementById(@container) if _.isString(@container)
    @iframe = this.createIframe(@container)
    @iframeDoc = @iframe.contentWindow.document
    @doc = new Tandem.Document(this)
    @ignoreDomChanges = false
    @currentSelection = null
    this.initContentListeners()
    this.initSelectionListeners()
    TandemEditor.editors.push(this)

  createIframe: (parent) ->
    html = parent.innerHTML
    parent.innerHTML = ''
    iframe = document.createElement('iframe')
    iframe.frameborder = 0
    iframe.src = 'javascript:;'
    iframe.height = iframe.width = '100%'
    parent.appendChild(iframe)
    doc = iframe.contentWindow.document
    head = doc.getElementsByTagName('head')[0]
    style = doc.createElement('style')
    style.type = 'text/css'
    css = "
      body { 
        font-family: 'Helvetica', 'Arial', san-serif;
        font-size: 13px;
        margin: 0px; 
        padding: 0px; 
      }
      .line { min-height: 15px; }
      a { text-decoration: underline; }
      b { font-weight: bold; }
      i { font-style: italic; }
      s { text-decoration: line-through; }
      u { text-decoration: underline; }
    "
    if style.styleSheet?
      style.styleSheet.cssText = css
    else
      style.appendChild(doc.createTextNode(css))
    head.appendChild(style)
    doc.body.setAttribute('contenteditable', true)
    doc.body.innerHTML = html
    return iframe

  initContentListeners: ->
    @iframeDoc.body.addEventListener('DOMCharacterDataModified', (event) =>
      @currentSelection = this.getSelection()
      return if @ignoreDomChanges
      docLength = @iframeDoc.body.textContent.length + @iframeDoc.body.childNodes.length - 1
      originalDocLength = docLength - (event.newValue.length - event.prevValue.length)
      deltas = []
      position = new Tandem.Position(this, event.srcElement.parentNode, 0)
      startIndex = position.getIndex()
      deltas.push(new JetRetain(0, startIndex)) if startIndex > 0
      insertedLength = 0
      offsetLength = 0
      dmp = new diff_match_patch()
      diffs = dmp.diff_main(event.prevValue, event.newValue)
      _.each(diffs, (diff) ->
        if diff[0] == DIFF_EQUAL
          deltas.push(new JetRetain(startIndex + offsetLength, startIndex + offsetLength + diff[1].length))
          offsetLength += diff[1].length
        if diff[0] == DIFF_INSERT
          deltas.push(new JetInsert(diff[1]))
          insertedLength += diff[1].length
        if diff[0] == DIFF_DELETE
          offsetLength += diff[1].length
      )
      deltas.push(new JetRetain(startIndex + offsetLength, originalDocLength)) if startIndex < docLength
      delta = new JetDelta(originalDocLength, docLength, deltas)
      this.emit(this.events.USER_TEXT_CHANGE, delta)
    )
    @iframeDoc.body.addEventListener('keydown', (event) =>
      return if @ignoreDomChanges || event.which != 13
      @currentSelection = this.getSelection()
      @ignoreDomChanges = true
      selection = @currentSelection
      startIndex = selection.start.getIndex()
      docLength = @iframeDoc.body.textContent.length + @iframeDoc.body.childNodes.length - 1
      deltas = []
      deltas.push(new JetRetain(0, startIndex)) if startIndex > 0
      deltas.push(new JetInsert("\n"))
      deltas.push(new JetRetain(startIndex, docLength)) if startIndex < docLength
      delta = new JetDelta(docLength, docLength + 1, deltas)
      this.emit(this.events.USER_TEXT_CHANGE, delta)
      setTimeout(=>
        @doc.buildLines()
        @ignoreDomChanges = false
      , 1)
    )

  initSelectionListeners: ->
    checkSelectionChange = =>
      selection = this.getSelection()
      if selection != @currentSelection && ((selection? && !selection.equals(@currentSelection)) || !@currentSelection.equals(selection))
        this.emit(this.events.USER_SELECTION_CHANGE, selection)
        @currentSelection = selection

    @iframeDoc.body.addEventListener('keyup', _.debounce(checkSelectionChange, 100))
    @iframeDoc.body.addEventListener('mouseup', _.debounce(checkSelectionChange, 100))
    setInterval(checkSelectionChange, this.options.POLL_INTERVAL)

  insertAt: (startIndex, text) ->
    oldIgnoreDomChange = @ignoreDomChanges
    @ignoreDomChanges = true
    position = Tandem.Position.makePosition(this, startIndex)
    startIndex = position.getIndex()

    this.preserveSelection(position, text.length, =>
      lines = text.split("\n")
      _.each(lines, (line, lineIndex) =>
        position = new Tandem.Position(this, startIndex) unless position?
        this.insertTextAt(position, line)
        startIndex += line.length
        if lineIndex < lines.length - 1
          this.insertNewlineAt(startIndex)
          startIndex += 1
        position = null
      )
      @doc.buildLines()
    )
    @ignoreDomChanges = oldIgnoreDomChange

  insertNewlineAt: (startIndex) ->
    [line, offset] = @doc.findLineAtOffset(startIndex)
    @doc.splitLine(line, offset)

  insertTextAt: (startIndex, text) ->
    position = Tandem.Position.makePosition(this, startIndex)
    position.leaf.setText(position.leaf.text.substr(0, position.offset) + text + position.leaf.text.substr(position.offset))

  deleteAt: (startIndex, length) ->
    oldIgnoreDomChange = @ignoreDomChanges
    @ignoreDomChanges = true
    startPos = Tandem.Position.makePosition(this, startIndex)
    startIndex = startPos.getIndex()
    endPos = Tandem.Position.makePosition(this, startIndex + length)
    endIndex = endPos.getIndex()

    this.preserveSelection(startPos, 0 - length, =>
      fragment = Tandem.Utils.Node.extract(this, startIndex, endIndex)
      @doc.buildLines()
    )
    @ignoreDomChanges = oldIgnoreDomChange

  getAt: (startIndex, length) ->
    # - Returns array of {text: "", attr: {}}
    # 1. Get all nodes in the range
    # 2. For first and last, change the text
    # 3. Return array
    # - Helper to get nodes in given index range
    # - In the case of 0 lenght, text will always be "", but attributes should be properly applied

  getSelection: ->
    return Tandem.Range.getSelection(this)

  applyAttributeToLine: (line, startOffset, endOffset, attr, value) ->
    return if startOffset == endOffset
    [startNode, startNodeOffset] = Tandem.Utils.Node.getChildAtOffset(line, startOffset)
    [prevNode, startNode] = Tandem.Utils.Node.split(startNode, startNodeOffset)
    [endNode, endNodeOffset] = Tandem.Utils.Node.getChildAtOffset(line, endOffset)
    [endNode, nextNode] = Tandem.Utils.Node.split(endNode, endNodeOffset)
    if value == true
      fragment = @iframeDoc.createDocumentFragment()
      Tandem.Utils.Node.traverseSiblings(startNode, endNode, (node) ->
        fragment.appendChild(node)
      )
      attrNode = Tandem.Utils.createContainerForAttribute(@iframeDoc, attr)
      attrNode.appendChild(fragment)
      line.insertBefore(attrNode, nextNode)
    else
      Tandem.Utils.Node.traverseSiblings(startNode, endNode, (node) ->
        Tandem.Utils.Node.removeAttributeFromSubtree(node, attr)
      )

  # applyAttribute: (TandemRange range, String attr, Mixed value) ->
  # applyAttribute: (Number startIndex, Number length, String attr, Mixed value) ->
  applyAttribute: (startIndex, length, attr, value, emitEvent = true) ->
    oldIgnoreDomChange = @ignoreDomChanges
    @ignoreDomChanges = true
    if !_.isNumber(startIndex)
      [range, attr, value] = [startIndex, length, attr]
      startIndex = range.start.getIndex()
      length = range.end.getIndex() - startIndex
    else
      range = new Tandem.Range(this, startIndex, startIndex + length)

    this.preserveSelection(range.start, 0, =>
      [startLine, startLineOffset] = Tandem.Utils.Node.getChildAtOffset(@iframeDoc.body, startIndex)
      [endLine, endLineOffset] = Tandem.Utils.Node.getChildAtOffset(@iframeDoc.body, startIndex + length)
      if startLine == endLine
        this.applyAttributeToLine(startLine, startLineOffset, endLineOffset, attr, value)
      else
        this.applyAttributeToLine(startLine, startLineOffset, startLine.textContent.length, attr, value)
        this.applyAttributeToLine(endLine, 0, endLineOffset, attr, value)
        curLine = startLine.nextSibling
        while curLine? && curLine != endLine
          this.applyAttributeToLine(curLine, 0, curLine.textContent.length, attr, value)
          curLine = curLine.nextSibling
      @doc.buildLines()
    )
    if emitEvent
      docLength = @iframeDoc.body.textContent.length + @iframeDoc.body.childNodes.length - 1
      deltas = []
      deltas.push(new JetRetain(0, startIndex)) if startIndex > 0
      attribute = {}
      attribute[attr] = value
      deltas.push(new JetRetain(startIndex, startIndex + length, attribute))
      deltas.push(new JetRetain(startIndex + length, docLength)) if startIndex + length < docLength
      delta = new JetDelta(docLength, docLength, deltas)
      this.emit(this.events.API_TEXT_CHANGE, delta)
    @ignoreDomChanges = oldIgnoreDomChange
    
  preserveSelection: (modificationStart, charAdditions, fn) ->
    currentSelection = this.getSelection()
    if currentSelection?
      [selStart, selEnd] = this.transformSelection(modificationStart, currentSelection, charAdditions)
      fn()
      savedSelectionRange = new Tandem.Range(currentSelection.editor, selStart, selEnd)
      rangySel = rangy.getSelection(@iframe.contentWindow)
      range = savedSelectionRange.getRangy()
      rangySel.setSingleRange(range)
    else
      fn()

  transformSelection: (modificationStart, selectionRange, charAdditions) ->
    modPos = modificationStart.getIndex()
    selStart = selectionRange.start.getIndex()
    selEnd = selectionRange.end.getIndex()
    selStart = Math.max(selStart + charAdditions, modPos) if modPos <= selStart
    selEnd = Math.max(selEnd + charAdditions, modPos) if modPos < selEnd
    return [selStart, selEnd]


window.Tandem ||= {}
window.Tandem.Editor = TandemEditor
