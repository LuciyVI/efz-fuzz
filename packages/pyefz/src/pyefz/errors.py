"""Stable failures from the local runtime and transport."""


class EFZError(Exception):
    code = "efz_error"

    def __init__(self, message, *, code=None):
        super().__init__(message)
        if code is not None:
            self.code = code


class BadConfig(EFZError, ValueError):
    code = "bad_config"


class ProviderFailure(EFZError):
    code = "provider_failure"


class ProviderBusy(EFZError):
    code = "provider_busy"


class RequestTimeout(EFZError, TimeoutError):
    code = "request_timeout"


class ProviderTimeout(RequestTimeout):
    code = "provider_timeout"


class Cancelled(EFZError):
    code = "cancelled"


class ProtocolError(EFZError):
    code = "protocol_error"


class RuntimeUnavailable(EFZError):
    code = "runtime_unavailable"


class StorageError(EFZError):
    code = "storage_error"


class ReplayFailure(EFZError):
    code = "replay_failure"


_ERRORS = {cls.code: cls for cls in (BadConfig, ProviderFailure, ProviderBusy, RequestTimeout, ProviderTimeout,
    Cancelled, ProtocolError, RuntimeUnavailable, StorageError, ReplayFailure)}


def remote_error(value):
    if not isinstance(value, dict) or set(value) != {"code", "message"}:
        raise ProtocolError("Invalid error response")
    code, message = value["code"], value["message"]
    if not isinstance(code, str) or not isinstance(message, str):
        raise ProtocolError("Invalid error response")
    return _ERRORS.get(code, EFZError)(message, code=code)
