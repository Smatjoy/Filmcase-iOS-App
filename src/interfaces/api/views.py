from urllib.parse import urlencode

from django import http
from django import shortcuts
from django import urls
from django.views import generic

from src.data import models
from src.domain.recipes import queries as recipe_queries
from src.domain.settings import queries as settings_queries
from src.interfaces.images import views as image_views
from src.interfaces.recipes import views as recipe_views

_DEFAULT_PAGE_SIZE = 24
_MAX_PAGE_SIZE = 100
_FALLBACK_THUMBNAIL_WIDTH = 600


class _InvalidParameter(Exception):
    pass


def _thumbnail_url(image_id: int | None) -> str | None:
    if image_id is None:
        return None
    return urls.reverse("api-image-thumbnail", kwargs={"image_id": image_id})


def _image_url(image_id: int | None) -> str | None:
    if image_id is None:
        return None
    return urls.reverse("api-image-file", kwargs={"image_id": image_id})


def _number(value: object) -> float | None:
    """A Decimal setting as a JSON number, or None when the recipe does not use it."""
    return None if value is None else float(value)  # type: ignore[arg-type]


def _positive_int_param(request: http.HttpRequest, name: str, *, default: int, maximum: int | None = None) -> int:
    raw = request.GET.get(name)
    if raw is None or raw == "":
        return default
    try:
        value = int(raw)
    except ValueError:
        raise _InvalidParameter(f"{name} must be a positive integer.")
    if value < 1 or (maximum is not None and value > maximum):
        bound = f" no greater than {maximum}" if maximum is not None else ""
        raise _InvalidParameter(f"{name} must be a positive integer{bound}.")
    return value


def _page_link(request: http.HttpRequest, page_number: int | None) -> str | None:
    if page_number is None:
        return None
    query = request.GET.copy()
    query["page"] = str(page_number)
    return f"{request.path}?{urlencode(query, doseq=True)}"


def _version(position: int | None) -> dict[str, object] | None:
    if position is None:
        return None
    return {"position": position, "label": f"v{position}"}


def _recipe_summary(recipe: recipe_queries.RecipeData, *, version_position: int | None) -> dict[str, object]:
    return {
        "id": recipe.id,
        "name": recipe.name,
        "film_simulation": recipe.film_simulation,
        "dynamic_range": recipe.dynamic_range,
        "grain_roughness": recipe.grain_roughness,
        "color_chrome_effect": recipe.color_chrome_effect,
        "white_balance": recipe.white_balance,
        "image_count": recipe.image_count,
        "version": _version(version_position),
        "cover_thumbnail_url": _thumbnail_url(recipe.cover_image_id),
    }


class RecipeList(generic.View):
    """
    List recipes a page at a time, filtered exactly as the recipe explorer is.

    Query params: ``page``, ``page_size`` (at most 100), ``name_search``, and the
    explorer's facet fields (``film_simulation=Provia&film_simulation=...``,
    ``sensors``, ...). The facet options for the current filters come back under
    ``facets``, so a client can build the same sidebar.
    """

    def get(self, request: http.HttpRequest) -> http.HttpResponse:
        try:
            page_number = _positive_int_param(request, "page", default=1)
            page_size = _positive_int_param(request, "page_size", default=_DEFAULT_PAGE_SIZE, maximum=_MAX_PAGE_SIZE)
        except _InvalidParameter as e:
            return http.JsonResponse({"error": str(e)}, status=400)
        gallery = recipe_queries.get_recipe_gallery_data(
            active_filters=recipe_views._recipe_explorer_filters_from_request(request),
            name_search=request.GET.get("name_search", "").strip(),
            page_number=page_number,
            page_size=page_size,
        )
        page = gallery.page_obj
        versions = recipe_queries.get_version_positions(recipe_ids=[r.id for r in page.items])
        return http.JsonResponse({
            "count": page.total_count,
            "next": _page_link(request, page.next_page_number),
            "previous": _page_link(request, page.previous_page_number),
            "results": [_recipe_summary(r, version_position=versions.get(r.id)) for r in page.items],
            "facets": gallery.sidebar_options,
        })


class RecipeDetail(generic.View):
    """
    Return every setting of one recipe, with its collections and version line.

    :raises Http404: if no recipe with the given ID exists.
    """

    def get(self, request: http.HttpRequest, recipe_id: int) -> http.HttpResponse:
        try:
            detail = recipe_queries.get_recipe_detail(recipe_id=recipe_id)
        except models.FujifilmRecipe.DoesNotExist:
            raise http.Http404
        recipe = detail.recipe
        try:
            line = recipe_queries.get_recipes_in_version_line(recipe_id=recipe_id).recipes
        except recipe_queries.RecipeNotInVersionLineError:
            line = ()
        current = next((v for v in line if v.is_current), None)
        return http.JsonResponse({
            "id": recipe.id,
            "name": recipe.name,
            "description": recipe.description,
            "film_simulation": recipe.film_simulation,
            "dynamic_range": recipe.dynamic_range,
            "d_range_priority": recipe.d_range_priority,
            "grain_roughness": recipe.grain_roughness,
            "grain_size": recipe.grain_size,
            "color_chrome_effect": recipe.color_chrome_effect,
            "color_chrome_fx_blue": recipe.color_chrome_fx_blue,
            "white_balance": recipe.white_balance,
            "white_balance_red": recipe.white_balance_red,
            "white_balance_blue": recipe.white_balance_blue,
            "highlight": _number(recipe.highlight),
            "shadow": _number(recipe.shadow),
            "color": _number(recipe.color),
            "sharpness": _number(recipe.sharpness),
            "high_iso_nr": _number(recipe.high_iso_nr),
            "clarity": _number(recipe.clarity),
            "monochromatic_color_warm_cool": _number(recipe.monochromatic_color_warm_cool),
            "monochromatic_color_magenta_green": _number(recipe.monochromatic_color_magenta_green),
            "is_monochromatic": detail.is_monochromatic,
            "sensors": list(recipe.sensors),
            "bodies": list(recipe.bodies),
            "image_count": recipe.image_count,
            "version": _version(current.position if current else None),
            "version_line": [
                {"id": v.recipe_id, "name": v.name, "position": v.position, "label": v.label, "is_current": v.is_current}
                for v in line
            ],
            "collections": [
                {"id": c.id, "name": c.name, "recipe_count": c.recipe_count}
                for c in detail.collections
            ],
            "cover_image_url": _image_url(recipe.cover_image_id),
            "cover_thumbnail_url": _thumbnail_url(recipe.cover_image_id),
            "camera_payload_url": urls.reverse("api-recipe-camera-payload", kwargs={"recipe_id": recipe.id}),
        })


class CollectionList(generic.View):
    """
    List collections, filtered as the collections page is.

    Query params: ``name_search``, ``recipe_name_search`` and repeated
    ``film_simulation``. Not paginated: the collections page is not either.
    """

    def get(self, request: http.HttpRequest) -> http.HttpResponse:
        summaries = recipe_queries.get_collection_summaries(
            name_search=request.GET.get("name_search", "").strip(),
            recipe_name_search=request.GET.get("recipe_name_search", "").strip(),
            film_simulations=request.GET.getlist("film_simulation"),
        )
        return http.JsonResponse({
            "count": len(summaries),
            "results": [
                {
                    "id": c.id,
                    "name": c.name,
                    "recipe_count": c.recipe_count,
                    "film_simulations": [fs.film_simulation for fs in c.film_sims],
                    "cover_thumbnail_urls": [_thumbnail_url(image_id) for image_id in c.mosaic_image_ids],
                }
                for c in summaries
            ],
        })


class CollectionDetail(generic.View):
    """
    Return one collection with its recipes in stored order.

    :raises Http404: if no collection with the given ID exists.
    """

    def get(self, request: http.HttpRequest, collection_id: int) -> http.HttpResponse:
        try:
            detail = recipe_queries.get_collection_detail(collection_id=collection_id)
        except recipe_queries.CollectionNotFound:
            raise http.Http404
        return http.JsonResponse({
            "id": detail.id,
            "name": detail.name,
            "recipe_ids": [m.recipe_id for m in detail.members],
            "recipes": [
                {
                    "id": m.recipe_id,
                    "name": m.name,
                    "film_simulation": m.film_simulation,
                    "image_count": m.image_count,
                    "position": m.position,
                }
                for m in detail.members
            ],
        })


class ImageThumbnail(generic.View):
    """
    Serve an image resized to the first configured thumbnail width.

    The same cached thumbnail the browser's image route serves, behind the token.

    :raises Http404: if no image with the given ID exists, or the file is missing on disk.
    """

    def get(self, request: http.HttpRequest, image_id: int) -> http.HttpResponseBase:
        image = shortcuts.get_object_or_404(models.Image, pk=image_id)
        widths = settings_queries.get_thumbnail_widths()
        width = widths[0] if widths else _FALLBACK_THUMBNAIL_WIDTH
        return image_views.serve_image_file(image=image, width_param=str(width))


class ImageFile(generic.View):
    """
    Serve the original image file.

    :raises Http404: if no image with the given ID exists, or the file is missing on disk.
    """

    def get(self, request: http.HttpRequest, image_id: int) -> http.HttpResponseBase:
        image = shortcuts.get_object_or_404(models.Image, pk=image_id)
        return image_views.serve_image_file(image=image, width_param=None)


class NotFound(generic.View):
    """
    Answer any unrouted ``/api/`` path with a JSON 404.

    :raises Http404: always.
    """

    def get(self, request: http.HttpRequest, *args: object, **kwargs: object) -> http.HttpResponse:
        raise http.Http404
