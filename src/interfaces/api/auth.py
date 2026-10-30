"""
Bearer-token protection for the JSON API under ``/api/``.

A decorator rather than middleware: the project has no middleware stack, and the
routes it guards are listed in one urls module, so the scope is visible where the
routes are declared and nothing outside ``/api/`` can be touched by accident.
"""
import functools
import hmac
from collections.abc import Callable

from django import http
from django.conf import settings

_ALLOWED_METHODS = ("GET", "HEAD")

_NOT_CONFIGURED_ERROR = (
    "The API is disabled because FILMCASE_API_TOKEN is not set on the server. "
    "Set it to a long random value and restart Filmcase."
)

ViewFunc = Callable[..., http.HttpResponseBase]


def _bearer_token(request: http.HttpRequest) -> str | None:
    scheme, _, credentials = request.headers.get("Authorization", "").partition(" ")
    if scheme.lower() != "bearer":
        return None
    return credentials.strip() or None


def _token_matches(*, presented: str, expected: str) -> bool:
    # Compared as bytes: compare_digest rejects non-ASCII str, and a client is free
    # to send whatever it likes.
    return hmac.compare_digest(presented.encode("utf-8"), expected.encode("utf-8"))


def api_view(view: ViewFunc) -> ViewFunc:
    """
    Wrap *view* so that it is reachable only with the configured bearer token.

    Fails closed: with ``FILMCASE_API_TOKEN`` empty every request is answered 503,
    because the server can be reachable beyond the LAN and an open API is never
    acceptable. The token is checked before anything else, so an unauthenticated
    caller cannot tell a missing record from an existing one. Only GET (and HEAD)
    are served. A ``Http404`` raised by the wrapped view is answered as JSON, which
    is what lets the existing camera views be mirrored here unchanged.
    """

    @functools.wraps(view)
    def wrapper(request: http.HttpRequest, *args: object, **kwargs: object) -> http.HttpResponseBase:
        expected: str = settings.FILMCASE_API_TOKEN
        if not expected:
            return http.JsonResponse({"error": _NOT_CONFIGURED_ERROR}, status=503)
        presented = _bearer_token(request)
        if presented is None or not _token_matches(presented=presented, expected=expected):
            response = http.JsonResponse({"error": "A valid bearer token is required."}, status=401)
            response["WWW-Authenticate"] = "Bearer"
            return response
        if request.method not in _ALLOWED_METHODS:
            response = http.JsonResponse({"error": "Method not allowed."}, status=405)
            response["Allow"] = "GET, HEAD"
            return response
        try:
            return view(request, *args, **kwargs)
        except http.Http404:
            return http.JsonResponse({"error": "Not found."}, status=404)

    return wrapper
