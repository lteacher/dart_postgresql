part of postgresql.impl;

class ConnectionImpl implements Connection {

  ConnectionImpl._private(
      this._socket,
      Settings settings,
      this._applicationName,
      this._timeZone,
      TypeConverter typeConverter,
      String getDebugName())
    : _userName = settings.user,
      _passwordHash = _md5s(settings.password + settings.user),
      _databaseName = settings.database,
      _typeConverter = typeConverter == null
          ? new TypeConverter()
          : typeConverter,
      _getDebugName = getDebugName,
      _buffer = new Buffer((msg) => new PostgresqlException(msg, getDebugName()));

  ConnectionState get state => _state;
  ConnectionState _state = notConnected;

  TransactionState _transactionState = unknown;
  TransactionState get transactionState => _transactionState;

  @deprecated TransactionState get transactionStatus => _transactionState;

  final String _databaseName;
  final String _userName;
  final String _passwordHash;
  final String _applicationName;
  final String _timeZone;
  final TypeConverter _typeConverter;
  final Socket _socket;
  final Buffer _buffer;
  bool _hasConnected = false;
  final Completer _connected = new Completer();
  final Queue<_Query> _sendQueryQueue = new Queue<_Query>();
  _Query _query;
  int _msgType;
  int _msgLength;
  int _secretKey;
  bool _isUtcTimeZone = false;

  int _backendPid;
  final _getDebugName;

  int get backendPid => _backendPid;

  String get debugName => _getDebugName();

  String toString() => '$debugName:$_backendPid';

  final Map<String,String> _parameters = new Map<String, String>();

  Map<String,String> _parametersView;

  Map<String,String> get parameters {
    if (_parametersView == null)
      _parametersView = new UnmodifiableMapView(_parameters);
    return _parametersView;
  }

  Stream get messages => _messages.stream;

  @deprecated Stream<Message> get unhandled => messages;

  final StreamController _messages = new StreamController.broadcast();

  static Future<ConnectionImpl> connect(
      String uri,
      {Duration connectionTimeout,
       String applicationName,
       String timeZone,
       TypeConverter typeConverter,
       String getDebugName(),
       Future<Socket> mockSocketConnect(String host, int port)}) {

    return new Future.sync(() {

      var settings = new Settings.fromUri(uri);

      //FIXME Currently this timeout doesn't cancel the socket connection
      // process.
      // There is a bug open about adding a real socket connect timeout
      // parameter to Socket.connect() if this happens then start using it.
      // http://code.google.com/p/dart/issues/detail?id=19120
      if (connectionTimeout == null)
        connectionTimeout = new Duration(seconds: 180);

      getDebugName = getDebugName == null ? () => 'pgconn' : getDebugName;

      var onTimeout = () => throw new PostgresqlException(
          'Postgresql connection timed out. Timeout: $connectionTimeout.',
          getDebugName());

      var connectFunc = mockSocketConnect == null
          ? Socket.connect
          : mockSocketConnect;

      Future<Socket> future = connectFunc(settings.host, settings.port)
          .timeout(connectionTimeout, onTimeout: onTimeout);

      if (settings.requireSsl) future = _connectSsl(future);

      return future.timeout(connectionTimeout, onTimeout: onTimeout).then((socket) {

        var conn = new ConnectionImpl._private(socket, settings,
            applicationName, timeZone, typeConverter, getDebugName);

        socket.listen(conn._readData,
            onError: conn._handleSocketError,
            onDone: conn._handleSocketClosed);

        conn._state = socketConnected;
        conn._sendStartupMessage();
        return conn._connected.future;
      });
    });
  }

  static String _md5s(String s) {
    var hash = new MD5();
    hash.add(s.codeUnits.toList());
    return CryptoUtils.bytesToHex(hash.close());
  }

  //TODO yuck - this needs a rewrite.
  static Future<SecureSocket> _connectSsl(Future<Socket> future) {

    var completer = new Completer<SecureSocket>();

    future.then((socket) {

      socket.listen((data) {
        if (data == null || data[0] != _S) {
          socket.destroy();
          completer.completeError(
              new PostgresqlException(
                  'This postgresql server is not configured to support SSL '
                  'connections.', null)); //FIXME ideally pass the connection pool name through to this exception.
        } else {
          // TODO add option to only allow valid certs.
          // Note libpq also defaults to ignoring bad certificates, so this is
          // expected behaviour.
          // TODO consider adding a warning if certificate is invalid so that it
          // is at least logged.
          new Future.sync(() => SecureSocket.secure(socket, onBadCertificate: (cert) => true))
            .then((s) => completer.complete(s))
            .catchError((e) => completer.completeError(e));
        }
      });

      // Write header, and SSL magic number.
      socket.add([0, 0, 0, 8, 4, 210, 22, 47]);

    })
    .catchError((e) {
      completer.completeError(e);
    });

    return completer.future;
  }

  void _sendStartupMessage() {
    if (_state != socketConnected)
      throw new PostgresqlException(
          'Invalid state during startup.', _getDebugName());

    var msg = new MessageBuffer();
    msg.addInt32(0); // Length padding.
    msg.addInt32(_PROTOCOL_VERSION);
    msg.addUtf8String('user');
    msg.addUtf8String(_userName);
    msg.addUtf8String('database');
    msg.addUtf8String(_databaseName);
    msg.addUtf8String('client_encoding');
    msg.addUtf8String('UTF8');
    if (_timeZone != null) {
      msg.addUtf8String('TimeZone');
      msg.addUtf8String(_timeZone);
    }
    if (_applicationName != null) {
      msg.addUtf8String('application_name');
      msg.addUtf8String(_applicationName);
    }
    msg.addByte(0);
    msg.setLength(startup: true);

    _socket.add(msg.buffer);

    _state = authenticating;
  }

  void _readAuthenticationRequest(int msgType, int length) {
    assert(_buffer.bytesAvailable >= length);

    if (_state != authenticating)
      throw new PostgresqlException(
          'Invalid connection state while authenticating.', _getDebugName());

    int authType = _buffer.readInt32();

    if (authType == _AUTH_TYPE_OK) {
      _state = authenticated;
      return;
    }

    // Only MD5 authentication is supported.
    if (authType != _AUTH_TYPE_MD5) {
      throw new PostgresqlException('Unsupported or unknown authentication '
          'type: ${_authTypeAsString(authType)}, only MD5 authentication is '
          'supported.', _getDebugName());
    }

    var bytes = _buffer.readBytes(4);
    var salt = new String.fromCharCodes(bytes);
    var md5 = 'md5' + _md5s('${_passwordHash}$salt');

    // Build message.
    var msg = new MessageBuffer();
    msg.addByte(_MSG_PASSWORD);
    msg.addInt32(0);
    msg.addUtf8String(md5);
    msg.setLength();

    _socket.add(msg.buffer);
  }

  void _readReadyForQuery(int msgType, int length) {
    assert(_buffer.bytesAvailable >= length);

    int c = _buffer.readByte();

    if (c == _I || c == _T || c == _E) {

      if (c == _I)
        _transactionState = none;
      else if (c == _T)
        _transactionState = begun;
      else if (c == _E)
        _transactionState = error;

      var was = _state;

      _state = idle;

      if (_query != null) {
        _query.close();
        _query = null;
      }

      if (was == authenticated) {
        _hasConnected = true;
        _connected.complete(this);
      }

      new Future(() => _processSendQueryQueue());

    } else {
      _destroy();
      throw new PostgresqlException('Unknown ReadyForQuery transaction status: '
          '${_itoa(c)}.', _getDebugName());
    }
  }

  void _handleSocketError(error, {bool closed: false}) {

    if (_state == closed) {
      _messages.add(new ClientMessageImpl(
          isError: false,
          severity: 'WARNING',
          message: 'Socket error after socket closed.',
          connectionName: _getDebugName(),
          exception: error));
      _destroy();
      return;
    }

    _destroy();

    var msg = closed ? 'Socket closed unexpectedly.' : 'Socket error.';

    if (!_hasConnected) {
      _connected.completeError(new PostgresqlException(msg, _getDebugName(),
          exception: error));
    } else if (_query != null) {
      _query.addError(new PostgresqlException(msg, _getDebugName(),
          exception: error));
    } else {
      _messages.add(new ClientMessage(
          isError: true, connectionName: _getDebugName(), severity: 'ERROR',
          message: msg, exception: error));
    }
  }

  void _handleSocketClosed() {
    if (_state != closed) {
      _handleSocketError(null, closed: true);
    }
  }

  void _readData(List<int> data) {

    try {

      if (_state == closed)
        return;

      _buffer.append(data);

      // Handle resuming after storing message type and length.
      if (_msgType != null) {
        if (_msgLength > _buffer.bytesAvailable)
            return; // Wait for entire message to be in buffer.

        _readMessage(_msgType, _msgLength);

        _msgType = null;
        _msgLength = null;
      }

      // Main message loop.
      while (_state != closed) {

        if (_buffer.bytesAvailable < 5)
          return; // Wait for more data.

        // Message length is the message length excluding the message type code, but
        // including the 4 bytes for the length fields. Only the length of the body
        // is passed to each of the message handlers.
        int msgType = _buffer.readByte();
        int length = _buffer.readInt32() - 4;

        if (!_checkMessageLength(msgType, length + 4)) {
          throw new PostgresqlException('Lost message sync.', _getDebugName());
        }

        if (length > _buffer.bytesAvailable) {
          // Wait for entire message to be in buffer.
          // Store type, and length for when more data becomes available.
          _msgType =  msgType;
          _msgLength = length;
          return;
        }

        _readMessage(msgType, length);
      }

    } on Exception {
      _destroy();
      rethrow;
    }
  }

  bool _checkMessageLength(int msgType, int msgLength) {

    if (_state == authenticating) {
      if (msgLength < 8) return false;
      if (msgType == _MSG_AUTH_REQUEST && msgLength > 2000) return false;
      if (msgType == _MSG_ERROR_RESPONSE && msgLength > 30000) return false;
    } else {
      if (msgLength < 4) return false;

      // These are the only messages from the server which may exceed 30,000
      // bytes.
      if (msgLength > 30000 && (msgType != _MSG_NOTICE_RESPONSE
          && msgType != _MSG_ERROR_RESPONSE
          && msgType != _MSG_COPY_DATA
          && msgType != _MSG_ROW_DESCRIPTION
          && msgType != _MSG_DATA_ROW
          && msgType != _MSG_FUNCTION_CALL_RESPONSE
          && msgType != _MSG_NOTIFICATION_RESPONSE)) {
        return false;
      }
    }
    return true;
  }

  void _readMessage(int msgType, int length) {

    int pos = _buffer.bytesRead;

    switch (msgType) {

      case _MSG_AUTH_REQUEST:     _readAuthenticationRequest(msgType, length); break;
      case _MSG_READY_FOR_QUERY:  _readReadyForQuery(msgType, length); break;

      case _MSG_ERROR_RESPONSE:
      case _MSG_NOTICE_RESPONSE:
                                  _readErrorOrNoticeResponse(msgType, length); break;

      case _MSG_BACKEND_KEY_DATA: _readBackendKeyData(msgType, length); break;
      case _MSG_PARAMETER_STATUS: _readParameterStatus(msgType, length); break;

      case _MSG_ROW_DESCRIPTION:  _readRowDescription(msgType, length); break;
      case _MSG_DATA_ROW:         _readDataRow(msgType, length); break;
      case _MSG_EMPTY_QUERY_REPONSE: assert(length == 0); break;
      case _MSG_COMMAND_COMPLETE: _readCommandComplete(msgType, length); break;

      default:
        throw new PostgresqlException('Unknown, or unimplemented message: '
            '${UTF8.decode([msgType])}.', _getDebugName());
    }

    if (pos + length != _buffer.bytesRead)
      throw new PostgresqlException('Lost message sync.', _getDebugName());
  }

  void _readErrorOrNoticeResponse(int msgType, int length) {
    assert(_buffer.bytesAvailable >= length);

    var map = new Map<String, String>();
    int errorCode = _buffer.readByte();
    while (errorCode != 0) {
      var msg = _buffer.readUtf8String(length); //TODO check length remaining.
      map[new String.fromCharCode(errorCode)] = msg;
      errorCode = _buffer.readByte();
    }

    var msg = new ServerMessageImpl(
                         msgType == _MSG_ERROR_RESPONSE,
                         map,
                         _getDebugName());

    var ex = new PostgresqlException(msg.message, _getDebugName(),
        serverMessage: msg);

    if (msgType == _MSG_ERROR_RESPONSE) {
      if (!_hasConnected) {
          _state = closed;
          _socket.destroy();
          _connected.completeError(ex);
      } else if (_query != null) {
        _query.addError(ex);
      } else {
        _messages.add(msg);
      }
    } else {
      _messages.add(msg);
    }
  }

  void _readBackendKeyData(int msgType, int length) {
    assert(_buffer.bytesAvailable >= length);
    _backendPid = _buffer.readInt32();
    _secretKey = _buffer.readInt32();
  }

  void _readParameterStatus(int msgType, int length) {
    assert(_buffer.bytesAvailable >= length);
    var name = _buffer.readUtf8String(10000);
    var value = _buffer.readUtf8String(10000);

    warn(msg) {
      _messages.add(new ClientMessageImpl(
        severity: 'WARNING',
        message: msg,
        connectionName: _getDebugName()));
    }

    _parameters[name] = value;

    // Cache this value so that it doesn't need to be looked up from the map.
    if (name == 'TimeZone') {
      _isUtcTimeZone = value == 'UTC';
    }

    if (name == 'client_encoding' && value != 'UTF8') {
      warn('client_encoding parameter must remain as UTF8 for correct string '
           'handling. client_encoding is: "$value".');
    }
  }

  Stream query(String sql, [values]) {
    try {
      if (values != null)
        sql = substitute(sql, values, _typeConverter.encode);
      var query = _enqueueQuery(sql);
      return query.stream;
    } on Exception catch (ex, st) {
      return new Stream.fromFuture(new Future.error(ex, st));
    }
  }

  Future<int> execute(String sql, [values]) {
    try {
      if (values != null)
        sql = substitute(sql, values, _typeConverter.encode);

      var query = _enqueueQuery(sql);
      return query.stream.isEmpty.then((_) => query._rowsAffected);
    } on Exception catch (ex, st) {
      return new Future.error(ex, st);
    }
  }

  Stream queryMulti(String sql,[Iterable values]) async* {
    for (var valueSet in values) {
      yield* await query(sql,valueSet);
    }
  }

  Future<int> executeMulti(String sql,[Iterable values]) async {
    var futures = values.fold(new List(),(prev,curr) {
      prev.add(execute(sql,curr));
      return prev;
    });

    return await new Stream.fromFutures(futures).reduce((i,j) => i+j);
  }

  Future runInTransaction(Future operation(), [Isolation isolation = readCommitted]) {

    var begin = 'begin';
    if (isolation == repeatableRead)
      begin = 'begin; set transaction isolation level repeatable read;';
    else if (isolation == serializable)
      begin = 'begin; set transaction isolation level serializable;';

    return execute(begin)
      .then((_) => operation())
      .then((_) => execute('commit'))
      .catchError((e, st) {
        return execute('rollback')
          .then((_) => new Future.error(e, st));
      });
  }

  _Query _enqueueQuery(String sql) {

    if (sql == null || sql == '')
      throw new PostgresqlException(
          'SQL query is null or empty.', _getDebugName());

    if (sql.contains('\u0000'))
      throw new PostgresqlException(
          'Sql query contains a null character.', _getDebugName());

    if (_state == closed)
      throw new PostgresqlException(
          'Connection is closed, cannot execute query.', _getDebugName());

    var query = new _Query(sql);
    _sendQueryQueue.addLast(query);

    new Future(() => _processSendQueryQueue());

    return query;
  }

  void _processSendQueryQueue() {

    if (_sendQueryQueue.isEmpty)
      return;

    if (_query != null)
      return;

    if (_state == closed)
      return;

    assert(_state == idle);

    _query = _sendQueryQueue.removeFirst();

    var msg = new MessageBuffer();
    msg.addByte(_MSG_QUERY);
    msg.addInt32(0); // Length padding.
    msg.addUtf8String(_query.sql);
    msg.setLength();

    _socket.add(msg.buffer);

    _state = busy;
    _query._state = _BUSY;
    _transactionState = unknown;
  }

  void _readRowDescription(int msgType, int length) {

    assert(_buffer.bytesAvailable >= length);

    _state = streaming;

    int count = _buffer.readInt16();
    var list = new List<_Column>(count);

    for (int i = 0; i < count; i++) {
      var name = _buffer.readUtf8String(length); //TODO better maxSize.
      int fieldId = _buffer.readInt32();
      int tableColNo = _buffer.readInt16();
      int fieldType = _buffer.readInt32();
      int dataSize = _buffer.readInt16();
      int typeModifier = _buffer.readInt32();
      int formatCode = _buffer.readInt16();

      list[i] = new _Column(i, name, fieldId, tableColNo, fieldType, dataSize, typeModifier, formatCode);
    }

    _query._columnCount = count;
    _query._columns = new UnmodifiableListView(list);
    _query._commandIndex++;

    _query.addRowDescription();
  }

  void _readDataRow(int msgType, int length) {

    assert(_buffer.bytesAvailable >= length);

    int columns = _buffer.readInt16();
    for (var i = 0; i < columns; i++) {
      int size = _buffer.readInt32();
      _readColumnData(i, size);
    }
  }

  void _readColumnData(int index, int colSize) {

    assert(_buffer.bytesAvailable >= colSize);

    if (index == 0)
      _query._rowData = new List<dynamic>(_query._columns.length);

    if (colSize == -1) {
      _query._rowData[index] = null;
    } else {
      var col = _query._columns[index];
      if (col.isBinary) throw new PostgresqlException(
          'Binary result set parsing is not implemented.', _getDebugName());

      var str = _buffer.readUtf8StringN(colSize);

      var value = _typeConverter.decode(str, col.fieldType,
          isUtcTimeZone: _isUtcTimeZone, getConnectionName: _getDebugName);

      _query._rowData[index] = value;
    }

    // If last column, then return the row.
    if (index == _query._columnCount - 1)
      _query.addRow();
  }

  void _readCommandComplete(int msgType, int length) {

    assert(_buffer.bytesAvailable >= length);

    var commandString = _buffer.readUtf8String(length);
    int rowsAffected =
        int.parse(commandString.split(' ').last, onError: (_) => null);

    _query._commandIndex++;
    _query._rowsAffected = rowsAffected;
  }

  void close() {

    if (_state == closed)
      return;

    _state = closed;

    // If a query is in progress then send an error and close the result stream.
    if (_query != null) {
      var c = _query._controller;
      if (c != null && !c.isClosed) {
        c.addError(new PostgresqlException(
            'Connection closed before query could complete', _getDebugName()));
        c.close();
        _query = null;
      }
    }

    Future flushing;
    try {
      var msg = new MessageBuffer();
      msg.addByte(_MSG_TERMINATE);
      msg.addInt32(0);
      msg.setLength();
      _socket.add(msg.buffer);
      flushing = _socket.flush();
    } on Exception catch (e, st) {
      _messages.add(new ClientMessageImpl(
          severity: 'WARNING',
          message: 'Exception while closing connection. Closed without sending '
            'terminate message.',
          connectionName: _getDebugName(),
          exception: e,
          stackTrace: st));
    }

    // Wait for socket flush to succeed or fail before closing the connection.
    flushing.whenComplete(_destroy);
  }

  void _destroy() {
    _state = closed;
    _socket.destroy();
    new Future(() => _messages.close());
  }

}
