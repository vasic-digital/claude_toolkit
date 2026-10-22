"""http_noredirect.py - the ONE shared urllib opener policy for requests that
carry a credential (Authorization / x-api-key).

urllib's default opener follows 3xx redirects and RE-SENDS the request headers
(Authorization included) to whatever Location names - a key-exfiltration path
for any endpoint a user can configure. Every credential-bearing call in this
toolkit goes through here instead:

  NoRedirect          refuses every redirect (the 3xx surfaces as HTTPError)
  SameOriginRedirect  follows a redirect only when scheme, host and port are
                      unchanged (a trailing-slash 301 still works); any
                      cross-origin or scheme-downgrading hop is refused
  open_url(...)       build_opener(<handler>, HTTPSHandler(context)).open(...)
"""
import urllib.request
from urllib.parse import urlsplit


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuses every redirect: returning None makes urllib raise the 3xx as an
    HTTPError instead of re-sending the request to the new location."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class SameOriginRedirect(urllib.request.HTTPRedirectHandler):
    """Follows a redirect only to the identical scheme://host:port."""
    @staticmethod
    def _origin(url):
        u = urlsplit(url)
        port = u.port or (443 if u.scheme == "https" else 80 if u.scheme == "http" else None)
        return (u.scheme, (u.hostname or "").lower(), port)

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if self._origin(newurl) != self._origin(req.full_url):
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def open_url(req, timeout=None, context=None, same_origin=False):
    """Open `req` with the credential-safe redirect policy above."""
    handlers = [SameOriginRedirect() if same_origin else NoRedirect()]
    if context is not None:
        handlers.append(urllib.request.HTTPSHandler(context=context))
    return urllib.request.build_opener(*handlers).open(req, timeout=timeout)
