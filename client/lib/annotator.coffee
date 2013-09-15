class @Annotator
  constructor: ->
    @_pages = []

  setPage: (page) =>
    # Initialize the page
    @_pages[page.pageNumber - 1] =
      textSegments: []
      imageSegments: []
      highlightsEnabled: false

  setTextContent: (pageNumber, textContent) =>
    @_pages[pageNumber - 1].textContent = textContent

  textLayer: (pageNumber) =>
    page = @_pages[pageNumber - 1]

    beginLayout: =>
      page.textSegmentsDone = false

    endLayout: =>
      page.textSegmentsDone = true

      @_enableHighligts pageNumber

    appendText: (geom) =>
      page.textSegments.push PDFJS.pdfTextSegment page.textContent, page.textSegments.length, geom

  imageLayer: (pageNumber) =>
    page = @_pages[pageNumber - 1]

    beginLayout: =>
      page.imageLayerDone = false

    endLayout: =>
      page.imageLayerDone = true

      @_enableHighligts pageNumber

    appendImage: (geom) =>
      page.imageSegments.push _.pick(geom, 'left', 'top', 'width', 'height')

  # For debugging: draw divs for all segments
  _showSegments: (pageNumber) =>
    page = @_pages[pageNumber - 1]
    $displayPage = $("#display-page-#{ pageNumber }")

    for segment in page.textSegments
      $displayPage.append(
        $('<div/>').addClass('segment text-segment').css _.pick(segment, 'left', 'top', 'width', 'height')
      )

    for segment in page.imageSegments
      $displayPage.append(
        $('<div/>').addClass('segment image-segment').css  _.pick(segment, 'left', 'top', 'width', 'height')
      )

  _findClosestSegment: (pageNumber, position) =>
    page = @_pages[pageNumber - 1]

    closestDistance = Number.MAX_VALUE
    closestSegmentIndex = -1

    for segment, i in page.textSegments
      distanceXLeft = position.left - segment.left
      distanceXRight = position.left - (segment.left + segment.width)

      distanceYTop = position.top - segment.top
      distanceYBottom = position.top - (segment.top + segment.height)

      distanceX = if Math.abs(distanceXLeft) < Math.abs(distanceXRight) then distanceXLeft else distanceXRight
      if position.left > segment.left and position.left < segment.left + segment.width
        distanceX = 0

      distanceY = if Math.abs(distanceYTop) < Math.abs(distanceYBottom) then distanceYTop else distanceYBottom
      if position.top > segment.top and position.top < segment.top + segment.height
        distanceY = 0

      distance = distanceX * distanceX + distanceY * distanceY
      if distance < closestDistance
        closestDistance = distance
        closestSegmentIndex = i

    closestSegmentIndex

  _normalizeStartEnd: (startPosition, startIndex, endPosition, endIndex) =>
    if startIndex < endIndex
      # We don't have to do anything
      return [startPosition, startIndex, endPosition, endIndex]
    else if startIndex > endIndex
      return [endPosition, endIndex, startPosition, startIndex]
    else
      # Start and end are in the same segment, we prefer the left point (and top)
      # TODO: What about right-to-left texts? Or top-down texts?
      if startPosition.left < endPosition.left
        return [startPosition, startIndex, endPosition, endIndex]
      else if startPosition.left > endPosition.left
        return [endPosition, endIndex, startPosition, startIndex]
      # Left coordinates are equal, we prefer top one
      else if startPosition.top < endPosition.top
        return [startPosition, startIndex, endPosition, endIndex]
      else
        return [endPosition, endIndex, startPosition, startIndex]

  _hideHiglight: (pageNumber) =>
    $("#display-page-#{ pageNumber } .highlight").remove()

  _showHighlight: (pageNumber, startPosition, startIndex, endPosition, endIndex) =>
    @_hideHiglight pageNumber

    return if startPosition is -1 or endPosition is -1

    [startPosition, startIndex, endPosition, endIndex] = @_normalizeStartEnd startPosition, startIndex, endPosition, endIndex

    page = @_pages[pageNumber - 1]
    $displayPage = $("#display-page-#{ pageNumber }")

    for segment in page.textSegments[startIndex..endIndex]
      $displayPage.append(
        $('<div/>').addClass('highlight').css _.pick(segment, 'left', 'top', 'width', 'height')
      )

  _openHighlight: (pageNumber) =>
    # TODO: Implement

  _closeHighlight: (pageNumber) =>
    @_hideHiglight pageNumber

    # TODO: Implement

  _enableHighligts: (pageNumber) =>
    page = @_pages[pageNumber - 1]

    return unless page.textSegmentsDone and page.imageLayerDone

    # Highlights already enabled for this page
    return if page.highlightsEnabled
    page.highlightsEnabled = true

    # For debugging
    #@_showSegments pageNumber

    highlightStartPosition = null
    highlightEndPosition = null
    highlightStartIndex = -1
    highlightEndIndex = -1

    $canvas = $("#display-page-#{ pageNumber } canvas")

    $canvas.mousemove (e) =>
      return if highlightStartIndex is -1

      offset = $canvas.offset()
      highlightEndPosition =
        left: e.pageX - offset.left
        top: e.pageY - offset.top
      highlightEndIndex = @_findClosestSegment pageNumber, highlightEndPosition

      return if highlightEndIndex is -1

      @_showHighlight pageNumber, highlightStartPosition, highlightStartIndex, highlightEndPosition, highlightEndIndex

    $canvas.mousedown (e) =>
      offset = $canvas.offset()
      highlightStartPosition =
        left: e.pageX - offset.left
        top: e.pageY - offset.top
      highlightStartIndex = @_findClosestSegment pageNumber, highlightStartPosition

    $canvas.mouseup (e) =>
      return if highlightStartIndex is -1

      offset = $canvas.offset()
      if highlightStartPosition.left is e.pageX - offset.left and highlightStartPosition.top is e.pageY - offset.top
        # Mouse went up at the same location that it started, we just cleanup
        @_closeHighlight pageNumber
      else
        @_openHighlight pageNumber

      highlightStartPosition = null
      highlightEndPosition = null
      highlightStartIndex = -1
      highlightEndIndex = -1

    $canvas.mouseleave (e) =>
      return if highlightStartIndex is -1

      @_closeHighlight pageNumber

      highlightStartPosition = null
      highlightEndPosition = null
      highlightStartIndex = -1
      highlightEndIndex = -1