class @Publication extends @Publication
  checkCache: =>
    if @cached
      return

    if not Storage.exists @filename()
      console.log "Caching PDF for #{ @_id } from the central server"

      pdf = HTTP.get 'http://stage.peerlibrary.org' + @url(),
        timeout: 10000 # ms
        encoding: null # PDFs are binary data

      Storage.save @filename(), pdf.content

    @cached = true
    Publications.update @_id, $set: cached: @cached

    pdf?.content

  process: (pdf, initCallback, textCallback, pageImageCallback, progressCallback) =>
    pdf ?= Storage.open @filename()
    initCallback ?= (numberOfPages) ->
    textCallback ?= (pageNumber, x, y, width, height, direction, text) ->
    pageImageCallback ?= (pageNumber, canvasElement) ->
    progressCallback ?= (progress) ->

    console.log "Processing PDF for #{ @_id }: #{ @filename() }"

    PDF.process pdf, initCallback, textCallback, pageImageCallback, progressCallback

    @processed = true
    Publications.update @_id, $set: processed: @processed

  # A subset of public fields used for search results to optimize transmission to a client
  # This list is applied to PUBLIC_FIELDS to get a subset
  @PUBLIC_SEARCH_RESULTS_FIELDS: ->
    [
      'slug'
      'created'
      'updated'
      'authors'
      'title'
      'numberOfPages'
    ]

  # A set of fields which are public and can be published to the client
  @PUBLIC_FIELDS: ->
    fields:
      slug: 1
      created: 1
      updated: 1
      authors: 1
      title: 1
      numberOfPages: 1
      abstract: 1
      doi: 1
      foreignId: 1
      source: 1
      importing: 1

Meteor.methods
  createPublication: (filename, sha256) ->
    if this.userId is null
      throw new Meteor.Error 403, 'User is not signed in.'

    publication = Publications.findOne
      sha256: sha256
    if publication
      # We already have the PDF, so just add it to the library
      Persons.update
        'user.id': this.userId
      ,
        $addToSet:
          library: publication._id
      throw new Meteor.Error 403, 'File already exists.'
    else
      Publications.insert
        created: moment.utc().toDate()
        updated: moment.utc().toDate()
        source: 'upload'
        importing:
          by:
            id: this.userId
          filename: filename
          uploadProgress: 0
          processProgress: 0
          sha256: sha256
        cached: false
        processed: false

  uploadPublication: (file) ->
    unless this.userId
      throw new Meteor.Error 401, 'User is not signed in.'
    unless file
      throw new Meteor.Error 403, 'File is null.'

    Publications.update
      _id: file.name.split('.')[0]
      'importing.by.id': this.userId
    ,
      $set:
        'importing.uploadProgress': ~~(100 * file.end / file.size)

    Storage.saveMeteorFile file


  finishPublicationUpload: (id) ->
    unless this.userId
      throw new Meteor.Error 401, 'User is not signed in.'

    publication = Publications.findOne
      _id: id
      'importing.by.id': this.userId

    unless publication
      throw new Meteor.Error 403, 'No publication importing.'

    # TODO: Read and hash in chunks, when we will be processing PDFs as well in chunks
    pdf = Storage.open publication.filename()

    hash = new Crypto.SHA256()
    hash.update pdf
    sha256 = hash.finalize()

    unless sha256 == publication.importing.sha256
      throw new Meteor.Error 403, 'Hash does not match.'
    existingPublication = Publications.findOne
      sha256: sha256
    if existingPublication
      throw new Meteor.Error 403, 'File already exists.'

    Publications.update
      _id: id
    ,
      $set:
        cached: true
        sha256: sha256

    publication.process null, null, null, null, (progress) ->
      Publications.update
        _id: id
      ,
        $set:
          'importing.processProgress': ~~(100 * progress)

  confirmPublication: (id, metadata) ->
    unless this.userId
      throw new Meteor.Error 401, 'User is not signed in.'

    Publications.update
      _id: id
      'importing.by.id': this.userId
      cached: true
    ,
      $set:
        _.extend _.pick(metadata or {}, 'authorsRaw', 'title', 'abstract', 'doi'),
          updated: moment.utc().toDate()
      $unset:
        importing: ''

    Persons.update
        'user.id': this.userId
      ,
        $addToSet:
          library: id

Meteor.publish 'publications-by-author-slug', (authorSlug) ->
  return unless authorSlug

  author = Persons.findOne
    slug: authorSlug

  Publications.find
    authorIds:
      $all: [author._id]
    cached: true
    processed: true
  ,
    Publication.PUBLIC_FIELDS()

Meteor.publish 'publications-by-id', (id) ->
  return unless id

  Publications.find
    _id: id
    cached: true
    processed: true
  ,
    Publication.PUBLIC_FIELDS()

Meteor.publish 'publications-by-ids', (ids) ->
  return unless ids?.length

  Publications.find
    _id: {$in: ids}
    cached: true
    processed: true
  ,
    Publication.PUBLIC_FIELDS()

Meteor.publish 'my-publications', ->
  # TODO: Should we use objects instead of lists? We are not interested in order, just existence in the set

  currentLibrary = []
  currentPersonId = null # Just for asserts
  handlePublications = null

  removePublications = (ids) =>
    for id in ids
      @removed 'Publications', id

  publishPublications = (newLibrary) =>
    newLibrary ||= []

    added = _.difference newLibrary, currentLibrary
    removed = _.difference currentLibrary, newLibrary
    currentLibrary = []

    oldHandlePublications = handlePublications
    handlePublications = Publications.find(
      _id:
        $in: newLibrary
      # TODO: Should be set as well
      # cached: true
      processed: true
    ,
      Publication.PUBLIC_FIELDS()
    ).observeChanges
      added: (id, fields) =>
        # We add only the newly added ones, others were added already before
        @added 'Publications', id, fields if _.contains added, id

        assert not _.contains currentLibrary, id
        currentLibrary.push id

      changed: (id, fields) =>
        @changed 'Publications', id, fields

      removed: (id) =>
        assert _.contains currentLibrary, id
        currentLibrary = _.without currentLibrary, id

        @removed 'Publications', id

    # We stop the handle after we established the new handle,
    # so that any possible changes hapenning in the meantime
    # were still processed by the old handle
    oldHandlePublications.stop() if oldHandlePublications

    # And then we remove those who are not in the library anymore
    removePublications removed

  handlePersons = Persons.find(
    'user.id': @userId
  ,
    fields:
      # id field is implicitly added
      'user.id': 1
      library: 1
  ).observeChanges
    added: (id, fields) =>
      # There should be only one person with the id at every given moment
      assert.equal currentPersonId, null
      assert.equal fields.user.id, @userId

      currentPersonId = id
      publishPublications fields.library

    changed: (id, fields) =>
      # Person should already be added
      assert.notEqual currentPersonId, null

      publishPublications fields.library

    removed: (id) =>
      # We cannot remove the person if we never added the person before
      assert.notEqual currentPersonId, null

      currentPersonId = null
      removePublications currentLibrary

  @ready()

  @onStop =>
    handlePersons.stop() if handlePersons
    handlePublications.stop() if handlePublications

Meteor.publish 'my-publications-importing', ->
  Publications.find
    'importing.by.id': @userId
  ,
    fields: _.extend Publication.PUBLIC_FIELDS().fields,
      cached: 1
      processed: 1