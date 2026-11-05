"""
Optional bearer-token protection, and the method rules, for the JSON API under ``/api/``.

A decorator rather than middleware: the project has no middleware stack, and the
routes it guards are listed in one urls module, so the scope is visible where the
routes are declared and nothing outside ``/api/`` can be touched by accident.
"""
import functools
import hmac
from collections.abc import Callable

from django import http
from django.conf import settings

_READ_METHODS = ("GET", "HEAD")

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


def api_view(view: ViewFunc, *, write_methods: tuple[str, ...] = ()) -> ViewFunc:
    """
    Wrap *view* as a JSON API route, read-only unless *write_methods* says otherwise.

    With ``FILMCASE_API_TOKEN`` set, the bearer token is required and checked before
    anything else, so an unauthenticated caller cannot tell a missing record from an
    existing one. With it empty the API is open, like the browser pages, which serve
    the same data without authentication and take the same changes. Only GET (and
    HEAD) and *write_methods* are served. A write must declare a JSON body: a page in
    a browser cannot send that across origins without a preflight this server does
    not answer, so another website cannot make a visitor's browser change anything. A ``Http404`` raised by the wrapped view is answered as JSON, which
    is what lets the existing camera views be mirrored here unchanged.
    """

    @functools.wraps(view)
    def wrapper(request: http.HttpRequest, *args: object, **kwargs: object) -> http.HttpResponseBase:
        expected: str = settings.FILMCASE_API_TOKEN
        if expected:
            presented = _bearer_token(request)
            if presented is None or not _token_matches(presented=presented, expected=expected):
                response = http.JsonResponse({"error": "A valid bearer token is required."}, status=401)
                response["WWW-Authenticate"] = "Bearer"
                return response
        allowed = (*_READ_METHODS, *write_methods)
        if request.method not in allowed:
            response = http.JsonResponse({"error": "Method not allowed."}, status=405)
            response["Allow"] = ", ".join(allowed)
            return response
        if request.method in write_methods and request.content_type != "application/json":
            return http.JsonResponse({"error": "Send the body as application/json."}, status=415)
        try:
            return view(request, *args, **kwargs)
        except http.Http404:
            return http.JsonResponse({"error": "Not found."}, status=404)

    return wrapper
