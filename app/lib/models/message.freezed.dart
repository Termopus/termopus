// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'message.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

Message _$MessageFromJson(Map<String, dynamic> json) {
  return _Message.fromJson(json);
}

/// @nodoc
mixin _$Message {
  String get id => throw _privateConstructorUsedError;
  MessageType get type => throw _privateConstructorUsedError;
  MessageSender get sender => throw _privateConstructorUsedError;
  String get content => throw _privateConstructorUsedError;
  DateTime get timestamp => throw _privateConstructorUsedError;

  /// Programming language for [MessageType.code] blocks.
  String? get language => throw _privateConstructorUsedError;

  /// Parsed diff lines for [MessageType.diff] messages.
  List<DiffLine>? get diffLines => throw _privateConstructorUsedError;

  /// Pending action for [MessageType.action] messages.
  PendingAction? get action => throw _privateConstructorUsedError;

  /// Tool name for [MessageType.toolUse] messages (e.g. "Edit", "Bash").
  String? get toolName => throw _privateConstructorUsedError;

  /// Tool execution status: "pending", "success", or "error".
  String? get toolStatus => throw _privateConstructorUsedError;

  /// Tool input data (file path, command, etc.).
  Map<String, dynamic>? get toolInput => throw _privateConstructorUsedError;

  /// Tool output/result text.
  String? get toolResult => throw _privateConstructorUsedError;

  /// Error message if tool execution failed.
  String? get toolError => throw _privateConstructorUsedError;

  /// Questions for [MessageType.askQuestion] messages.
  List<Map<String, dynamic>>? get questions =>
      throw _privateConstructorUsedError;

  /// Subagent ID for [MessageType.subagentEvent] messages.
  String? get agentId => throw _privateConstructorUsedError;

  /// Subagent type (e.g. "Explore", "Bash") for [MessageType.subagentEvent].
  String? get agentType => throw _privateConstructorUsedError;

  /// Subagent status: "started" or "stopped".
  String? get agentStatus => throw _privateConstructorUsedError;

  /// Transfer ID for file transfer messages.
  String? get transferId => throw _privateConstructorUsedError;

  /// File name for file transfer messages.
  String? get fileName => throw _privateConstructorUsedError;

  /// MIME type for file transfer messages.
  String? get mimeType => throw _privateConstructorUsedError;

  /// File size in bytes for file transfer messages.
  int? get fileSize => throw _privateConstructorUsedError;

  /// Transfer progress (0.0 - 1.0) for [MessageType.fileProgress].
  double? get transferProgress => throw _privateConstructorUsedError;

  /// Local file path after download for [MessageType.fileComplete].
  String? get localFilePath => throw _privateConstructorUsedError;

  /// Whether the transfer completed successfully.
  bool? get transferSuccess => throw _privateConstructorUsedError;

  /// Serializes this Message to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $MessageCopyWith<Message> get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $MessageCopyWith<$Res> {
  factory $MessageCopyWith(Message value, $Res Function(Message) then) =
      _$MessageCopyWithImpl<$Res, Message>;
  @useResult
  $Res call(
      {String id,
      MessageType type,
      MessageSender sender,
      String content,
      DateTime timestamp,
      String? language,
      List<DiffLine>? diffLines,
      PendingAction? action,
      String? toolName,
      String? toolStatus,
      Map<String, dynamic>? toolInput,
      String? toolResult,
      String? toolError,
      List<Map<String, dynamic>>? questions,
      String? agentId,
      String? agentType,
      String? agentStatus,
      String? transferId,
      String? fileName,
      String? mimeType,
      int? fileSize,
      double? transferProgress,
      String? localFilePath,
      bool? transferSuccess});

  $PendingActionCopyWith<$Res>? get action;
}

/// @nodoc
class _$MessageCopyWithImpl<$Res, $Val extends Message>
    implements $MessageCopyWith<$Res> {
  _$MessageCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? type = null,
    Object? sender = null,
    Object? content = null,
    Object? timestamp = null,
    Object? language = freezed,
    Object? diffLines = freezed,
    Object? action = freezed,
    Object? toolName = freezed,
    Object? toolStatus = freezed,
    Object? toolInput = freezed,
    Object? toolResult = freezed,
    Object? toolError = freezed,
    Object? questions = freezed,
    Object? agentId = freezed,
    Object? agentType = freezed,
    Object? agentStatus = freezed,
    Object? transferId = freezed,
    Object? fileName = freezed,
    Object? mimeType = freezed,
    Object? fileSize = freezed,
    Object? transferProgress = freezed,
    Object? localFilePath = freezed,
    Object? transferSuccess = freezed,
  }) {
    return _then(_value.copyWith(
      id: null == id
          ? _value.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      type: null == type
          ? _value.type
          : type // ignore: cast_nullable_to_non_nullable
              as MessageType,
      sender: null == sender
          ? _value.sender
          : sender // ignore: cast_nullable_to_non_nullable
              as MessageSender,
      content: null == content
          ? _value.content
          : content // ignore: cast_nullable_to_non_nullable
              as String,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as DateTime,
      language: freezed == language
          ? _value.language
          : language // ignore: cast_nullable_to_non_nullable
              as String?,
      diffLines: freezed == diffLines
          ? _value.diffLines
          : diffLines // ignore: cast_nullable_to_non_nullable
              as List<DiffLine>?,
      action: freezed == action
          ? _value.action
          : action // ignore: cast_nullable_to_non_nullable
              as PendingAction?,
      toolName: freezed == toolName
          ? _value.toolName
          : toolName // ignore: cast_nullable_to_non_nullable
              as String?,
      toolStatus: freezed == toolStatus
          ? _value.toolStatus
          : toolStatus // ignore: cast_nullable_to_non_nullable
              as String?,
      toolInput: freezed == toolInput
          ? _value.toolInput
          : toolInput // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
      toolResult: freezed == toolResult
          ? _value.toolResult
          : toolResult // ignore: cast_nullable_to_non_nullable
              as String?,
      toolError: freezed == toolError
          ? _value.toolError
          : toolError // ignore: cast_nullable_to_non_nullable
              as String?,
      questions: freezed == questions
          ? _value.questions
          : questions // ignore: cast_nullable_to_non_nullable
              as List<Map<String, dynamic>>?,
      agentId: freezed == agentId
          ? _value.agentId
          : agentId // ignore: cast_nullable_to_non_nullable
              as String?,
      agentType: freezed == agentType
          ? _value.agentType
          : agentType // ignore: cast_nullable_to_non_nullable
              as String?,
      agentStatus: freezed == agentStatus
          ? _value.agentStatus
          : agentStatus // ignore: cast_nullable_to_non_nullable
              as String?,
      transferId: freezed == transferId
          ? _value.transferId
          : transferId // ignore: cast_nullable_to_non_nullable
              as String?,
      fileName: freezed == fileName
          ? _value.fileName
          : fileName // ignore: cast_nullable_to_non_nullable
              as String?,
      mimeType: freezed == mimeType
          ? _value.mimeType
          : mimeType // ignore: cast_nullable_to_non_nullable
              as String?,
      fileSize: freezed == fileSize
          ? _value.fileSize
          : fileSize // ignore: cast_nullable_to_non_nullable
              as int?,
      transferProgress: freezed == transferProgress
          ? _value.transferProgress
          : transferProgress // ignore: cast_nullable_to_non_nullable
              as double?,
      localFilePath: freezed == localFilePath
          ? _value.localFilePath
          : localFilePath // ignore: cast_nullable_to_non_nullable
              as String?,
      transferSuccess: freezed == transferSuccess
          ? _value.transferSuccess
          : transferSuccess // ignore: cast_nullable_to_non_nullable
              as bool?,
    ) as $Val);
  }

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $PendingActionCopyWith<$Res>? get action {
    if (_value.action == null) {
      return null;
    }

    return $PendingActionCopyWith<$Res>(_value.action!, (value) {
      return _then(_value.copyWith(action: value) as $Val);
    });
  }
}

/// @nodoc
abstract class _$$MessageImplCopyWith<$Res> implements $MessageCopyWith<$Res> {
  factory _$$MessageImplCopyWith(
          _$MessageImpl value, $Res Function(_$MessageImpl) then) =
      __$$MessageImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String id,
      MessageType type,
      MessageSender sender,
      String content,
      DateTime timestamp,
      String? language,
      List<DiffLine>? diffLines,
      PendingAction? action,
      String? toolName,
      String? toolStatus,
      Map<String, dynamic>? toolInput,
      String? toolResult,
      String? toolError,
      List<Map<String, dynamic>>? questions,
      String? agentId,
      String? agentType,
      String? agentStatus,
      String? transferId,
      String? fileName,
      String? mimeType,
      int? fileSize,
      double? transferProgress,
      String? localFilePath,
      bool? transferSuccess});

  @override
  $PendingActionCopyWith<$Res>? get action;
}

/// @nodoc
class __$$MessageImplCopyWithImpl<$Res>
    extends _$MessageCopyWithImpl<$Res, _$MessageImpl>
    implements _$$MessageImplCopyWith<$Res> {
  __$$MessageImplCopyWithImpl(
      _$MessageImpl _value, $Res Function(_$MessageImpl) _then)
      : super(_value, _then);

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? type = null,
    Object? sender = null,
    Object? content = null,
    Object? timestamp = null,
    Object? language = freezed,
    Object? diffLines = freezed,
    Object? action = freezed,
    Object? toolName = freezed,
    Object? toolStatus = freezed,
    Object? toolInput = freezed,
    Object? toolResult = freezed,
    Object? toolError = freezed,
    Object? questions = freezed,
    Object? agentId = freezed,
    Object? agentType = freezed,
    Object? agentStatus = freezed,
    Object? transferId = freezed,
    Object? fileName = freezed,
    Object? mimeType = freezed,
    Object? fileSize = freezed,
    Object? transferProgress = freezed,
    Object? localFilePath = freezed,
    Object? transferSuccess = freezed,
  }) {
    return _then(_$MessageImpl(
      id: null == id
          ? _value.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      type: null == type
          ? _value.type
          : type // ignore: cast_nullable_to_non_nullable
              as MessageType,
      sender: null == sender
          ? _value.sender
          : sender // ignore: cast_nullable_to_non_nullable
              as MessageSender,
      content: null == content
          ? _value.content
          : content // ignore: cast_nullable_to_non_nullable
              as String,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as DateTime,
      language: freezed == language
          ? _value.language
          : language // ignore: cast_nullable_to_non_nullable
              as String?,
      diffLines: freezed == diffLines
          ? _value._diffLines
          : diffLines // ignore: cast_nullable_to_non_nullable
              as List<DiffLine>?,
      action: freezed == action
          ? _value.action
          : action // ignore: cast_nullable_to_non_nullable
              as PendingAction?,
      toolName: freezed == toolName
          ? _value.toolName
          : toolName // ignore: cast_nullable_to_non_nullable
              as String?,
      toolStatus: freezed == toolStatus
          ? _value.toolStatus
          : toolStatus // ignore: cast_nullable_to_non_nullable
              as String?,
      toolInput: freezed == toolInput
          ? _value._toolInput
          : toolInput // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
      toolResult: freezed == toolResult
          ? _value.toolResult
          : toolResult // ignore: cast_nullable_to_non_nullable
              as String?,
      toolError: freezed == toolError
          ? _value.toolError
          : toolError // ignore: cast_nullable_to_non_nullable
              as String?,
      questions: freezed == questions
          ? _value._questions
          : questions // ignore: cast_nullable_to_non_nullable
              as List<Map<String, dynamic>>?,
      agentId: freezed == agentId
          ? _value.agentId
          : agentId // ignore: cast_nullable_to_non_nullable
              as String?,
      agentType: freezed == agentType
          ? _value.agentType
          : agentType // ignore: cast_nullable_to_non_nullable
              as String?,
      agentStatus: freezed == agentStatus
          ? _value.agentStatus
          : agentStatus // ignore: cast_nullable_to_non_nullable
              as String?,
      transferId: freezed == transferId
          ? _value.transferId
          : transferId // ignore: cast_nullable_to_non_nullable
              as String?,
      fileName: freezed == fileName
          ? _value.fileName
          : fileName // ignore: cast_nullable_to_non_nullable
              as String?,
      mimeType: freezed == mimeType
          ? _value.mimeType
          : mimeType // ignore: cast_nullable_to_non_nullable
              as String?,
      fileSize: freezed == fileSize
          ? _value.fileSize
          : fileSize // ignore: cast_nullable_to_non_nullable
              as int?,
      transferProgress: freezed == transferProgress
          ? _value.transferProgress
          : transferProgress // ignore: cast_nullable_to_non_nullable
              as double?,
      localFilePath: freezed == localFilePath
          ? _value.localFilePath
          : localFilePath // ignore: cast_nullable_to_non_nullable
              as String?,
      transferSuccess: freezed == transferSuccess
          ? _value.transferSuccess
          : transferSuccess // ignore: cast_nullable_to_non_nullable
              as bool?,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _$MessageImpl implements _Message {
  const _$MessageImpl(
      {required this.id,
      required this.type,
      required this.sender,
      required this.content,
      required this.timestamp,
      this.language,
      final List<DiffLine>? diffLines,
      this.action,
      this.toolName,
      this.toolStatus,
      final Map<String, dynamic>? toolInput,
      this.toolResult,
      this.toolError,
      final List<Map<String, dynamic>>? questions,
      this.agentId,
      this.agentType,
      this.agentStatus,
      this.transferId,
      this.fileName,
      this.mimeType,
      this.fileSize,
      this.transferProgress,
      this.localFilePath,
      this.transferSuccess})
      : _diffLines = diffLines,
        _toolInput = toolInput,
        _questions = questions;

  factory _$MessageImpl.fromJson(Map<String, dynamic> json) =>
      _$$MessageImplFromJson(json);

  @override
  final String id;
  @override
  final MessageType type;
  @override
  final MessageSender sender;
  @override
  final String content;
  @override
  final DateTime timestamp;

  /// Programming language for [MessageType.code] blocks.
  @override
  final String? language;

  /// Parsed diff lines for [MessageType.diff] messages.
  final List<DiffLine>? _diffLines;

  /// Parsed diff lines for [MessageType.diff] messages.
  @override
  List<DiffLine>? get diffLines {
    final value = _diffLines;
    if (value == null) return null;
    if (_diffLines is EqualUnmodifiableListView) return _diffLines;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  /// Pending action for [MessageType.action] messages.
  @override
  final PendingAction? action;

  /// Tool name for [MessageType.toolUse] messages (e.g. "Edit", "Bash").
  @override
  final String? toolName;

  /// Tool execution status: "pending", "success", or "error".
  @override
  final String? toolStatus;

  /// Tool input data (file path, command, etc.).
  final Map<String, dynamic>? _toolInput;

  /// Tool input data (file path, command, etc.).
  @override
  Map<String, dynamic>? get toolInput {
    final value = _toolInput;
    if (value == null) return null;
    if (_toolInput is EqualUnmodifiableMapView) return _toolInput;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(value);
  }

  /// Tool output/result text.
  @override
  final String? toolResult;

  /// Error message if tool execution failed.
  @override
  final String? toolError;

  /// Questions for [MessageType.askQuestion] messages.
  final List<Map<String, dynamic>>? _questions;

  /// Questions for [MessageType.askQuestion] messages.
  @override
  List<Map<String, dynamic>>? get questions {
    final value = _questions;
    if (value == null) return null;
    if (_questions is EqualUnmodifiableListView) return _questions;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  /// Subagent ID for [MessageType.subagentEvent] messages.
  @override
  final String? agentId;

  /// Subagent type (e.g. "Explore", "Bash") for [MessageType.subagentEvent].
  @override
  final String? agentType;

  /// Subagent status: "started" or "stopped".
  @override
  final String? agentStatus;

  /// Transfer ID for file transfer messages.
  @override
  final String? transferId;

  /// File name for file transfer messages.
  @override
  final String? fileName;

  /// MIME type for file transfer messages.
  @override
  final String? mimeType;

  /// File size in bytes for file transfer messages.
  @override
  final int? fileSize;

  /// Transfer progress (0.0 - 1.0) for [MessageType.fileProgress].
  @override
  final double? transferProgress;

  /// Local file path after download for [MessageType.fileComplete].
  @override
  final String? localFilePath;

  /// Whether the transfer completed successfully.
  @override
  final bool? transferSuccess;

  @override
  String toString() {
    return 'Message(id: $id, type: $type, sender: $sender, content: $content, timestamp: $timestamp, language: $language, diffLines: $diffLines, action: $action, toolName: $toolName, toolStatus: $toolStatus, toolInput: $toolInput, toolResult: $toolResult, toolError: $toolError, questions: $questions, agentId: $agentId, agentType: $agentType, agentStatus: $agentStatus, transferId: $transferId, fileName: $fileName, mimeType: $mimeType, fileSize: $fileSize, transferProgress: $transferProgress, localFilePath: $localFilePath, transferSuccess: $transferSuccess)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$MessageImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.type, type) || other.type == type) &&
            (identical(other.sender, sender) || other.sender == sender) &&
            (identical(other.content, content) || other.content == content) &&
            (identical(other.timestamp, timestamp) ||
                other.timestamp == timestamp) &&
            (identical(other.language, language) ||
                other.language == language) &&
            const DeepCollectionEquality()
                .equals(other._diffLines, _diffLines) &&
            (identical(other.action, action) || other.action == action) &&
            (identical(other.toolName, toolName) ||
                other.toolName == toolName) &&
            (identical(other.toolStatus, toolStatus) ||
                other.toolStatus == toolStatus) &&
            const DeepCollectionEquality()
                .equals(other._toolInput, _toolInput) &&
            (identical(other.toolResult, toolResult) ||
                other.toolResult == toolResult) &&
            (identical(other.toolError, toolError) ||
                other.toolError == toolError) &&
            const DeepCollectionEquality()
                .equals(other._questions, _questions) &&
            (identical(other.agentId, agentId) || other.agentId == agentId) &&
            (identical(other.agentType, agentType) ||
                other.agentType == agentType) &&
            (identical(other.agentStatus, agentStatus) ||
                other.agentStatus == agentStatus) &&
            (identical(other.transferId, transferId) ||
                other.transferId == transferId) &&
            (identical(other.fileName, fileName) ||
                other.fileName == fileName) &&
            (identical(other.mimeType, mimeType) ||
                other.mimeType == mimeType) &&
            (identical(other.fileSize, fileSize) ||
                other.fileSize == fileSize) &&
            (identical(other.transferProgress, transferProgress) ||
                other.transferProgress == transferProgress) &&
            (identical(other.localFilePath, localFilePath) ||
                other.localFilePath == localFilePath) &&
            (identical(other.transferSuccess, transferSuccess) ||
                other.transferSuccess == transferSuccess));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hashAll([
        runtimeType,
        id,
        type,
        sender,
        content,
        timestamp,
        language,
        const DeepCollectionEquality().hash(_diffLines),
        action,
        toolName,
        toolStatus,
        const DeepCollectionEquality().hash(_toolInput),
        toolResult,
        toolError,
        const DeepCollectionEquality().hash(_questions),
        agentId,
        agentType,
        agentStatus,
        transferId,
        fileName,
        mimeType,
        fileSize,
        transferProgress,
        localFilePath,
        transferSuccess
      ]);

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$MessageImplCopyWith<_$MessageImpl> get copyWith =>
      __$$MessageImplCopyWithImpl<_$MessageImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$MessageImplToJson(
      this,
    );
  }
}

abstract class _Message implements Message {
  const factory _Message(
      {required final String id,
      required final MessageType type,
      required final MessageSender sender,
      required final String content,
      required final DateTime timestamp,
      final String? language,
      final List<DiffLine>? diffLines,
      final PendingAction? action,
      final String? toolName,
      final String? toolStatus,
      final Map<String, dynamic>? toolInput,
      final String? toolResult,
      final String? toolError,
      final List<Map<String, dynamic>>? questions,
      final String? agentId,
      final String? agentType,
      final String? agentStatus,
      final String? transferId,
      final String? fileName,
      final String? mimeType,
      final int? fileSize,
      final double? transferProgress,
      final String? localFilePath,
      final bool? transferSuccess}) = _$MessageImpl;

  factory _Message.fromJson(Map<String, dynamic> json) = _$MessageImpl.fromJson;

  @override
  String get id;
  @override
  MessageType get type;
  @override
  MessageSender get sender;
  @override
  String get content;
  @override
  DateTime get timestamp;

  /// Programming language for [MessageType.code] blocks.
  @override
  String? get language;

  /// Parsed diff lines for [MessageType.diff] messages.
  @override
  List<DiffLine>? get diffLines;

  /// Pending action for [MessageType.action] messages.
  @override
  PendingAction? get action;

  /// Tool name for [MessageType.toolUse] messages (e.g. "Edit", "Bash").
  @override
  String? get toolName;

  /// Tool execution status: "pending", "success", or "error".
  @override
  String? get toolStatus;

  /// Tool input data (file path, command, etc.).
  @override
  Map<String, dynamic>? get toolInput;

  /// Tool output/result text.
  @override
  String? get toolResult;

  /// Error message if tool execution failed.
  @override
  String? get toolError;

  /// Questions for [MessageType.askQuestion] messages.
  @override
  List<Map<String, dynamic>>? get questions;

  /// Subagent ID for [MessageType.subagentEvent] messages.
  @override
  String? get agentId;

  /// Subagent type (e.g. "Explore", "Bash") for [MessageType.subagentEvent].
  @override
  String? get agentType;

  /// Subagent status: "started" or "stopped".
  @override
  String? get agentStatus;

  /// Transfer ID for file transfer messages.
  @override
  String? get transferId;

  /// File name for file transfer messages.
  @override
  String? get fileName;

  /// MIME type for file transfer messages.
  @override
  String? get mimeType;

  /// File size in bytes for file transfer messages.
  @override
  int? get fileSize;

  /// Transfer progress (0.0 - 1.0) for [MessageType.fileProgress].
  @override
  double? get transferProgress;

  /// Local file path after download for [MessageType.fileComplete].
  @override
  String? get localFilePath;

  /// Whether the transfer completed successfully.
  @override
  bool? get transferSuccess;

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$MessageImplCopyWith<_$MessageImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

DiffLine _$DiffLineFromJson(Map<String, dynamic> json) {
  return _DiffLine.fromJson(json);
}

/// @nodoc
mixin _$DiffLine {
  String get content => throw _privateConstructorUsedError;
  DiffType get type => throw _privateConstructorUsedError;
  int get lineNumber => throw _privateConstructorUsedError;

  /// Serializes this DiffLine to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of DiffLine
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $DiffLineCopyWith<DiffLine> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $DiffLineCopyWith<$Res> {
  factory $DiffLineCopyWith(DiffLine value, $Res Function(DiffLine) then) =
      _$DiffLineCopyWithImpl<$Res, DiffLine>;
  @useResult
  $Res call({String content, DiffType type, int lineNumber});
}

/// @nodoc
class _$DiffLineCopyWithImpl<$Res, $Val extends DiffLine>
    implements $DiffLineCopyWith<$Res> {
  _$DiffLineCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of DiffLine
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? content = null,
    Object? type = null,
    Object? lineNumber = null,
  }) {
    return _then(_value.copyWith(
      content: null == content
          ? _value.content
          : content // ignore: cast_nullable_to_non_nullable
              as String,
      type: null == type
          ? _value.type
          : type // ignore: cast_nullable_to_non_nullable
              as DiffType,
      lineNumber: null == lineNumber
          ? _value.lineNumber
          : lineNumber // ignore: cast_nullable_to_non_nullable
              as int,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$DiffLineImplCopyWith<$Res>
    implements $DiffLineCopyWith<$Res> {
  factory _$$DiffLineImplCopyWith(
          _$DiffLineImpl value, $Res Function(_$DiffLineImpl) then) =
      __$$DiffLineImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String content, DiffType type, int lineNumber});
}

/// @nodoc
class __$$DiffLineImplCopyWithImpl<$Res>
    extends _$DiffLineCopyWithImpl<$Res, _$DiffLineImpl>
    implements _$$DiffLineImplCopyWith<$Res> {
  __$$DiffLineImplCopyWithImpl(
      _$DiffLineImpl _value, $Res Function(_$DiffLineImpl) _then)
      : super(_value, _then);

  /// Create a copy of DiffLine
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? content = null,
    Object? type = null,
    Object? lineNumber = null,
  }) {
    return _then(_$DiffLineImpl(
      content: null == content
          ? _value.content
          : content // ignore: cast_nullable_to_non_nullable
              as String,
      type: null == type
          ? _value.type
          : type // ignore: cast_nullable_to_non_nullable
              as DiffType,
      lineNumber: null == lineNumber
          ? _value.lineNumber
          : lineNumber // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _$DiffLineImpl implements _DiffLine {
  const _$DiffLineImpl(
      {required this.content, required this.type, required this.lineNumber});

  factory _$DiffLineImpl.fromJson(Map<String, dynamic> json) =>
      _$$DiffLineImplFromJson(json);

  @override
  final String content;
  @override
  final DiffType type;
  @override
  final int lineNumber;

  @override
  String toString() {
    return 'DiffLine(content: $content, type: $type, lineNumber: $lineNumber)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$DiffLineImpl &&
            (identical(other.content, content) || other.content == content) &&
            (identical(other.type, type) || other.type == type) &&
            (identical(other.lineNumber, lineNumber) ||
                other.lineNumber == lineNumber));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, content, type, lineNumber);

  /// Create a copy of DiffLine
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$DiffLineImplCopyWith<_$DiffLineImpl> get copyWith =>
      __$$DiffLineImplCopyWithImpl<_$DiffLineImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$DiffLineImplToJson(
      this,
    );
  }
}

abstract class _DiffLine implements DiffLine {
  const factory _DiffLine(
      {required final String content,
      required final DiffType type,
      required final int lineNumber}) = _$DiffLineImpl;

  factory _DiffLine.fromJson(Map<String, dynamic> json) =
      _$DiffLineImpl.fromJson;

  @override
  String get content;
  @override
  DiffType get type;
  @override
  int get lineNumber;

  /// Create a copy of DiffLine
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$DiffLineImplCopyWith<_$DiffLineImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

PendingAction _$PendingActionFromJson(Map<String, dynamic> json) {
  return _PendingAction.fromJson(json);
}

/// @nodoc
mixin _$PendingAction {
  String get id => throw _privateConstructorUsedError;
  String get prompt => throw _privateConstructorUsedError;

  /// e.g. ["Allow", "Deny"] or ["Yes", "No"].
  List<String> get options => throw _privateConstructorUsedError;

  /// Whether the user has already responded.
  bool get responded => throw _privateConstructorUsedError;

  /// The chosen response value, if any.
  String? get response => throw _privateConstructorUsedError;

  /// Serializes this PendingAction to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of PendingAction
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $PendingActionCopyWith<PendingAction> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $PendingActionCopyWith<$Res> {
  factory $PendingActionCopyWith(
          PendingAction value, $Res Function(PendingAction) then) =
      _$PendingActionCopyWithImpl<$Res, PendingAction>;
  @useResult
  $Res call(
      {String id,
      String prompt,
      List<String> options,
      bool responded,
      String? response});
}

/// @nodoc
class _$PendingActionCopyWithImpl<$Res, $Val extends PendingAction>
    implements $PendingActionCopyWith<$Res> {
  _$PendingActionCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of PendingAction
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? prompt = null,
    Object? options = null,
    Object? responded = null,
    Object? response = freezed,
  }) {
    return _then(_value.copyWith(
      id: null == id
          ? _value.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      prompt: null == prompt
          ? _value.prompt
          : prompt // ignore: cast_nullable_to_non_nullable
              as String,
      options: null == options
          ? _value.options
          : options // ignore: cast_nullable_to_non_nullable
              as List<String>,
      responded: null == responded
          ? _value.responded
          : responded // ignore: cast_nullable_to_non_nullable
              as bool,
      response: freezed == response
          ? _value.response
          : response // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$PendingActionImplCopyWith<$Res>
    implements $PendingActionCopyWith<$Res> {
  factory _$$PendingActionImplCopyWith(
          _$PendingActionImpl value, $Res Function(_$PendingActionImpl) then) =
      __$$PendingActionImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String id,
      String prompt,
      List<String> options,
      bool responded,
      String? response});
}

/// @nodoc
class __$$PendingActionImplCopyWithImpl<$Res>
    extends _$PendingActionCopyWithImpl<$Res, _$PendingActionImpl>
    implements _$$PendingActionImplCopyWith<$Res> {
  __$$PendingActionImplCopyWithImpl(
      _$PendingActionImpl _value, $Res Function(_$PendingActionImpl) _then)
      : super(_value, _then);

  /// Create a copy of PendingAction
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? prompt = null,
    Object? options = null,
    Object? responded = null,
    Object? response = freezed,
  }) {
    return _then(_$PendingActionImpl(
      id: null == id
          ? _value.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      prompt: null == prompt
          ? _value.prompt
          : prompt // ignore: cast_nullable_to_non_nullable
              as String,
      options: null == options
          ? _value._options
          : options // ignore: cast_nullable_to_non_nullable
              as List<String>,
      responded: null == responded
          ? _value.responded
          : responded // ignore: cast_nullable_to_non_nullable
              as bool,
      response: freezed == response
          ? _value.response
          : response // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _$PendingActionImpl implements _PendingAction {
  const _$PendingActionImpl(
      {required this.id,
      required this.prompt,
      required final List<String> options,
      this.responded = false,
      this.response})
      : _options = options;

  factory _$PendingActionImpl.fromJson(Map<String, dynamic> json) =>
      _$$PendingActionImplFromJson(json);

  @override
  final String id;
  @override
  final String prompt;

  /// e.g. ["Allow", "Deny"] or ["Yes", "No"].
  final List<String> _options;

  /// e.g. ["Allow", "Deny"] or ["Yes", "No"].
  @override
  List<String> get options {
    if (_options is EqualUnmodifiableListView) return _options;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_options);
  }

  /// Whether the user has already responded.
  @override
  @JsonKey()
  final bool responded;

  /// The chosen response value, if any.
  @override
  final String? response;

  @override
  String toString() {
    return 'PendingAction(id: $id, prompt: $prompt, options: $options, responded: $responded, response: $response)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$PendingActionImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.prompt, prompt) || other.prompt == prompt) &&
            const DeepCollectionEquality().equals(other._options, _options) &&
            (identical(other.responded, responded) ||
                other.responded == responded) &&
            (identical(other.response, response) ||
                other.response == response));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, id, prompt,
      const DeepCollectionEquality().hash(_options), responded, response);

  /// Create a copy of PendingAction
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$PendingActionImplCopyWith<_$PendingActionImpl> get copyWith =>
      __$$PendingActionImplCopyWithImpl<_$PendingActionImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$PendingActionImplToJson(
      this,
    );
  }
}

abstract class _PendingAction implements PendingAction {
  const factory _PendingAction(
      {required final String id,
      required final String prompt,
      required final List<String> options,
      final bool responded,
      final String? response}) = _$PendingActionImpl;

  factory _PendingAction.fromJson(Map<String, dynamic> json) =
      _$PendingActionImpl.fromJson;

  @override
  String get id;
  @override
  String get prompt;

  /// e.g. ["Allow", "Deny"] or ["Yes", "No"].
  @override
  List<String> get options;

  /// Whether the user has already responded.
  @override
  bool get responded;

  /// The chosen response value, if any.
  @override
  String? get response;

  /// Create a copy of PendingAction
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$PendingActionImplCopyWith<_$PendingActionImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
