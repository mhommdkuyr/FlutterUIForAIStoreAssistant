class RepositoryException implements Exception {
  final String message;
  const RepositoryException(this.message);

  @override
  String toString() => message;
}

class ValidationException extends RepositoryException {
  const ValidationException(String message) : super(message);
}

class DatabaseException extends RepositoryException {
  const DatabaseException(String message) : super(message);
}
