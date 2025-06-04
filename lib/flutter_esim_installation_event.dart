class EsimInstallationEvent {
  final String
      type; // Event type e.g., 'success', 'fail', 'unsupport', 'initiated'
  final dynamic data; // Original data payload from the native event

  EsimInstallationEvent(this.type, this.data);

  @override
  String toString() => 'EsimInstallationEvent(type: $type, data: $data)';
}
