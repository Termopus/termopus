// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'session.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

Session _$SessionFromJson(Map<String, dynamic> json) {
  return _Session.fromJson(json);
}

/// @nodoc
mixin _$Session {
  /// Unique session identifier (matches the relay session id).
  String get id => throw _privateConstructorUsedError;

  /// Human-readable name for the paired computer.
  String get name => throw _privateConstructorUsedError;

  /// Relay URL used to reach this computer.
  String get relay => throw _privateConstructorUsedError;

  /// When this device was first paired.
  DateTime get pairedAt => throw _privateConstructorUsedError;

  /// Last time a connection was established.
  DateTime? get lastConnected => throw _privateConstructorUsedError;

  /// Whether a live WebSocket connection is currently active.
  bool get isConnected => throw _privateConstructorUsedError;

  /// Serializes this Session to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of Session
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $SessionCopyWith<Session> get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SessionCopyWith<$Res> {
  factory $SessionCopyWith(Session value, $Res Function(Session) then) =
      _$SessionCopyWithImpl<$Res, Session>;
  @useResult
  $Res call(
      {String id,
      String name,
      String relay,
      DateTime pairedAt,
      DateTime? lastConnected,
      bool isConnected});
}

/// @nodoc
class _$SessionCopyWithImpl<$Res, $Val extends Session>
    implements $SessionCopyWith<$Res> {
  _$SessionCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of Session
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? name = null,
    Object? relay = null,
    Object? pairedAt = null,
    Object? lastConnected = freezed,
    Object? isConnected = null,
  }) {
    return _then(_value.copyWith(
      id: null == id
          ? _value.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      name: null == name
          ? _value.name
          : name // ignore: cast_nullable_to_non_nullable
              as String,
      relay: null == relay
          ? _value.relay
          : relay // ignore: cast_nullable_to_non_nullable
              as String,
      pairedAt: null == pairedAt
          ? _value.pairedAt
          : pairedAt // ignore: cast_nullable_to_non_nullable
              as DateTime,
      lastConnected: freezed == lastConnected
          ? _value.lastConnected
          : lastConnected // ignore: cast_nullable_to_non_nullable
              as DateTime?,
      isConnected: null == isConnected
          ? _value.isConnected
          : isConnected // ignore: cast_nullable_to_non_nullable
              as bool,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$SessionImplCopyWith<$Res> implements $SessionCopyWith<$Res> {
  factory _$$SessionImplCopyWith(
          _$SessionImpl value, $Res Function(_$SessionImpl) then) =
      __$$SessionImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String id,
      String name,
      String relay,
      DateTime pairedAt,
      DateTime? lastConnected,
      bool isConnected});
}

/// @nodoc
class __$$SessionImplCopyWithImpl<$Res>
    extends _$SessionCopyWithImpl<$Res, _$SessionImpl>
    implements _$$SessionImplCopyWith<$Res> {
  __$$SessionImplCopyWithImpl(
      _$SessionImpl _value, $Res Function(_$SessionImpl) _then)
      : super(_value, _then);

  /// Create a copy of Session
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? name = null,
    Object? relay = null,
    Object? pairedAt = null,
    Object? lastConnected = freezed,
    Object? isConnected = null,
  }) {
    return _then(_$SessionImpl(
      id: null == id
          ? _value.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      name: null == name
          ? _value.name
          : name // ignore: cast_nullable_to_non_nullable
              as String,
      relay: null == relay
          ? _value.relay
          : relay // ignore: cast_nullable_to_non_nullable
              as String,
      pairedAt: null == pairedAt
          ? _value.pairedAt
          : pairedAt // ignore: cast_nullable_to_non_nullable
              as DateTime,
      lastConnected: freezed == lastConnected
          ? _value.lastConnected
          : lastConnected // ignore: cast_nullable_to_non_nullable
              as DateTime?,
      isConnected: null == isConnected
          ? _value.isConnected
          : isConnected // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _$SessionImpl implements _Session {
  const _$SessionImpl(
      {required this.id,
      required this.name,
      required this.relay,
      required this.pairedAt,
      this.lastConnected,
      this.isConnected = false});

  factory _$SessionImpl.fromJson(Map<String, dynamic> json) =>
      _$$SessionImplFromJson(json);

  /// Unique session identifier (matches the relay session id).
  @override
  final String id;

  /// Human-readable name for the paired computer.
  @override
  final String name;

  /// Relay URL used to reach this computer.
  @override
  final String relay;

  /// When this device was first paired.
  @override
  final DateTime pairedAt;

  /// Last time a connection was established.
  @override
  final DateTime? lastConnected;

  /// Whether a live WebSocket connection is currently active.
  @override
  @JsonKey()
  final bool isConnected;

  @override
  String toString() {
    return 'Session(id: $id, name: $name, relay: $relay, pairedAt: $pairedAt, lastConnected: $lastConnected, isConnected: $isConnected)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SessionImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.relay, relay) || other.relay == relay) &&
            (identical(other.pairedAt, pairedAt) ||
                other.pairedAt == pairedAt) &&
            (identical(other.lastConnected, lastConnected) ||
                other.lastConnected == lastConnected) &&
            (identical(other.isConnected, isConnected) ||
                other.isConnected == isConnected));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType, id, name, relay, pairedAt, lastConnected, isConnected);

  /// Create a copy of Session
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$SessionImplCopyWith<_$SessionImpl> get copyWith =>
      __$$SessionImplCopyWithImpl<_$SessionImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$SessionImplToJson(
      this,
    );
  }
}

abstract class _Session implements Session {
  const factory _Session(
      {required final String id,
      required final String name,
      required final String relay,
      required final DateTime pairedAt,
      final DateTime? lastConnected,
      final bool isConnected}) = _$SessionImpl;

  factory _Session.fromJson(Map<String, dynamic> json) = _$SessionImpl.fromJson;

  /// Unique session identifier (matches the relay session id).
  @override
  String get id;

  /// Human-readable name for the paired computer.
  @override
  String get name;

  /// Relay URL used to reach this computer.
  @override
  String get relay;

  /// When this device was first paired.
  @override
  DateTime get pairedAt;

  /// Last time a connection was established.
  @override
  DateTime? get lastConnected;

  /// Whether a live WebSocket connection is currently active.
  @override
  bool get isConnected;

  /// Create a copy of Session
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$SessionImplCopyWith<_$SessionImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
