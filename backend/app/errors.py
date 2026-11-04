class AppError(Exception):
    def __init__(self, code, message, status=400, retryable=False, details=None):
        self.code = code
        self.message = message
        self.status = status
        self.retryable = retryable
        self.details = details
        super().__init__(message)

