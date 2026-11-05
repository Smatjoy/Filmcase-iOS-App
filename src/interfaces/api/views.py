import json
from decimal import Decimal
from urllib.parse import urlencode

from django import http
from django import shortcuts
from django import urls
from django.core import validators
from django.views import generic

from src.application.usecases.collections import create_collection as create_collection_uc
from src.application.usecases.collections import delete_collection as delete_collection_uc
from src.application.usecases.collections import update_collection as update_collection_uc
from src.application.usecases.recipes import create_recipe_manually as create_recipe_uc
from src.application.usecases.recipes import create_recipe_version as create_version_uc
from src.application.usecases.recipes import remove_recipes as remove_recipes_uc
from src.application.usecases.recipes import update_recipe_manually as update_recipe_uc
from src.data import models
from src.domain.recipes import constants as recipe_constants
from src.domain.recipes import operations as recipe_operations
from src.domain.recipes import queries as recipe_queries
from src.domain.settings import queries as settings_queries
from src.interfaces import forms as interface_forms
from src.interfaces.images import views as image_views
from src.interfaces.recipes import views as recipe_views

_DEFAULT_PAGE_SIZE = 24
_MAX_PAGE_SIZE = 100
_FALLBACK_THUMBNAIL_WIDTH = 600


class _InvalidParameter(Exception):
    pass


def _json_object(request: http.HttpRequest) -> dict[str, object]:
    try:
        body = json.loads(request.body)
    except ValueError:
        raise _InvalidParameter("The body must be JSON.")
    if not isinstance(body, dict):
        raise _InvalidParameter("The body must be a JSON object.")
    return body


def _bad_request(message: str) -> http.JsonResponse:
    return http.JsonResponse({"error": message}, status=400)


def _form_response(form: interface_forms.CreateRecipe) -> http.JsonResponse:
    """The form's errors: ``error`` to show, ``fields`` to mark each one."""
    fields = {name: [str(message) for message in errors] for name, errors in form.errors.items()}
    first = next(iter(form.errors.values()))[0]
    field = next(iter(form.errors))
    label = "" if field == "__all__" else f"{field.replace('_', ' ').capitalize()}: "
    return http.JsonResponse({"error": f"{label}{first}", "fields": fields}, status=400)


def _plain_values(values: dict[str, object]) -> dict[str, object]:
    """Form values as JSON numbers: a Decimal would otherwise be sent as a string."""
    return {key: float(value) if isinstance(value, Decimal) else value for key, value in values.items()}


def _stored_form_values(recipe: models.FujifilmRecipe) -> dict[str, object]:
    """*recipe* as the form takes it back, for a write that sends only what changed."""
    values = recipe_views.recipe_form_values(recipe)
    for field in ("sharpness", "high_iso_nr", "clarity"):
        if values[field] is None:
            values[field] = 0
    if values["grain_size"] is None:
        values["grain_size"] = "Off"
    return values


def _limits(field: object) -> dict[str, float]:
    limits: dict[str, float] = {}
    for validator in getattr(field, "validators", []):
        if isinstance(validator, validators.MinValueValidator):
            limits["min"] = float(validator.limit_value)
        elif isinstance(validator, validators.MaxValueValidator):
            limits["max"] = float(validator.limit_value)
    return limits


def _collection_fields(request: http.HttpRequest) -> tuple[str, list[int]]:
    """The ``name`` and ``recipe_ids`` of a collection write, checked as the browser's form does."""
    body = _json_object(request)
    form = interface_forms.Collection({"name": body.get("name")})
    if not form.is_valid():
        raise _InvalidParameter("Give the collection a name of up to 100 characters.")
    recipe_ids = body.get("recipe_ids", [])
    if not isinstance(recipe_ids, list) or not all(type(r) is int for r in recipe_ids):
        raise _InvalidParameter("recipe_ids must be a list of integers.")
    return form.cleaned_data["name"], recipe_ids


_COLLECTION_NAME_TAKEN = "A collection with this name already exists."
_COLLECTION_RECIPE_GONE = "One of the selected recipes no longer exists."


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


def _recipe_summary(
    recipe: recipe_queries.RecipeData, *, version_position: int | None, is_favorite: bool
) -> dict[str, object]:
    return {
        "id": recipe.id,
        "name": recipe.name,
        "film_simulation": recipe.film_simulation,
        "dynamic_range": recipe.dynamic_range,
        "grain_roughness": recipe.grain_roughness,
        "color_chrome_effect": recipe.color_chrome_effect,
        "white_balance": recipe.white_balance,
        "image_count": recipe.image_count,
        "is_favorite": is_favorite,
        "version": _version(version_position),
        "cover_thumbnail_url": _thumbnail_url(recipe.cover_image_id),
    }


class RecipeList(generic.View):
    """
    List recipes a page at a time, filtered exactly as the recipe explorer is.

    Query params: ``page``, ``page_size`` (at most 100), ``name_search``,
    ``favorite=true`` (only recipes with a favourite image), and the explorer's
    facet fields (``film_simulation=Provia&film_simulation=...``, ``sensors``, ...).
    The facet options for the current filters come back under ``facets``, so a
    client can build the same sidebar.
    """

    def post(self, request: http.HttpRequest) -> http.HttpResponse:
        """Create a recipe. The body is the recipe form as JSON."""
        try:
            form = interface_forms.CreateRecipe(data=_json_object(request))
        except _InvalidParameter as error:
            return _bad_request(str(error))
        if not form.is_valid():
            return _form_response(form)
        try:
            recipe = create_recipe_uc.create_recipe_manually(
                data=recipe_views.recipe_data_from_form(form.cleaned_data)
            )
        except create_recipe_uc.RecipeAlreadyExistsError as error:
            return _already_exists(error.name)
        except create_recipe_uc.InvalidRecipeDataError as error:
            return _bad_request(f"{error.field} has an invalid value.")
        return http.JsonResponse({"id": recipe.pk}, status=201)

    def get(self, request: http.HttpRequest) -> http.HttpResponse:
        try:
            page_number = _positive_int_param(request, "page", default=1)
            page_size = _positive_int_param(request, "page_size", default=_DEFAULT_PAGE_SIZE, maximum=_MAX_PAGE_SIZE)
        except _InvalidParameter as e:
            return http.JsonResponse({"error": str(e)}, status=400)
        gallery = recipe_queries.get_recipe_gallery_data(
            active_filters=recipe_views._recipe_explorer_filters_from_request(request),
            name_search=request.GET.get("name_search", "").strip(),
            favorites_only=request.GET.get("favorite", "").lower() in ("1", "true"),
            page_number=page_number,
            page_size=page_size,
        )
        page = gallery.page_obj
        recipe_ids = [r.id for r in page.items]
        versions = recipe_queries.get_version_positions(recipe_ids=recipe_ids)
        favorites = recipe_queries.get_favorite_recipe_ids(recipe_ids=recipe_ids)
        return http.JsonResponse({
            "count": page.total_count,
            "next": _page_link(request, page.next_page_number),
            "previous": _page_link(request, page.previous_page_number),
            "results": [
                _recipe_summary(r, version_position=versions.get(r.id), is_favorite=r.id in favorites)
                for r in page.items
            ],
            "facets": gallery.sidebar_options,
        })


class RecipeFormOptions(generic.View):
    """
    What the recipe editor offers: the choices and numeric ranges of the browser's form.
    """

    _STEPS = {"highlight": 0.5, "shadow": 0.5}

    def get(self, request: http.HttpRequest) -> http.HttpResponse:
        form = interface_forms.CreateRecipe()
        choices = {}
        ranges = {}
        for name, field in form.fields.items():
            if hasattr(field, "choices"):
                choices[name] = [value for value, _ in field.choices]
            limits = _limits(field)
            if limits:
                ranges[name] = {**limits, "step": self._STEPS.get(name, 1)}
        return http.JsonResponse({
            "choices": choices,
            "ranges": ranges,
            "monochromatic_film_simulations": sorted(recipe_constants.MONOCHROMATIC_FILM_SIMULATIONS),
        })


class RecipeFormValues(generic.View):
    """
    One recipe as the editor shows it, and how much of it may change: a recipe with
    images keeps its settings, so only the name and description can be edited.

    :raises Http404: if no recipe with the given ID exists.
    """

    def get(self, request: http.HttpRequest, recipe_id: int) -> http.HttpResponse:
        recipe = shortcuts.get_object_or_404(models.FujifilmRecipe, pk=recipe_id)
        return http.JsonResponse({
            "is_editable": recipe_queries.recipe_is_editable(recipe_id=recipe.pk),
            "has_version_line": _version_line_id(recipe) is not None,
            "values": _plain_values(_stored_form_values(recipe)),
        })


def _version_line_id(recipe: models.FujifilmRecipe) -> int | None:
    member = models.RecipeGroupMember.objects.filter(
        recipe=recipe, group_type=models.RecipeGroup.GROUP_TYPE_VERSION_LINE
    ).first()
    return None if member is None else member.group.pk


class RecipeVersions(generic.View):
    """
    Add a version to a recipe's version line. The body is the recipe form as JSON,
    on top of the source recipe's values.

    :raises Http404: if no recipe with the given ID exists.
    """

    def post(self, request: http.HttpRequest, recipe_id: int) -> http.HttpResponse:
        recipe = shortcuts.get_object_or_404(models.FujifilmRecipe, pk=recipe_id)
        group_id = _version_line_id(recipe)
        if group_id is None:
            return _bad_request("This recipe has no version line.")
        try:
            body = _json_object(request)
        except _InvalidParameter as error:
            return _bad_request(str(error))
        form = interface_forms.CreateRecipe(data={**_stored_form_values(recipe), **body})
        if not form.is_valid():
            return _form_response(form)
        try:
            created = create_version_uc.create_recipe_version(
                data=recipe_views.recipe_data_from_form(form.cleaned_data), group_id=group_id
            )
        except create_version_uc.RecipeAlreadyExistsError as error:
            return _already_exists(error.name)
        except create_version_uc.InvalidRecipeDataError as error:
            return _bad_request(f"{error.field} has an invalid value.")
        return http.JsonResponse({"id": created.pk}, status=201)


def _already_exists(name: str | None) -> http.JsonResponse:
    existing = name if name else "(unnamed)"
    return _bad_request(f'A recipe like this already exists with name "{existing}".')


class RecipeRemove(generic.View):
    """
    Remove a recipe. A recipe with images cannot be removed.

    :raises Http404: if no recipe with the given ID exists.
    """

    def post(self, request: http.HttpRequest, recipe_id: int) -> http.HttpResponse:
        result = remove_recipes_uc.remove_recipes(recipe_ids=[recipe_id], remove_recipe_card_file=False)
        if result.failures:
            if result.failures[0].is_has_images:
                return _bad_request("This recipe has images, so it cannot be removed.")
            raise http.Http404
        return http.JsonResponse({"removed": recipe_id})


class RecipeName(generic.View):
    """
    Set the display name of a recipe. The body is ``{"name": "..."}``.

    :raises Http404: if no recipe with the given ID exists.
    """

    def post(self, request: http.HttpRequest, recipe_id: int) -> http.HttpResponse:
        recipe = shortcuts.get_object_or_404(models.FujifilmRecipe, pk=recipe_id)
        try:
            name = _json_object(request).get("name")
        except _InvalidParameter as error:
            return http.JsonResponse({"error": str(error)}, status=400)
        try:
            if not isinstance(name, str):
                raise recipe_operations.RecipeNameValidationError(str(name))
            recipe_operations.set_recipe_name(recipe=recipe, name=name.strip())
        except recipe_operations.RecipeNameValidationError:
            return http.JsonResponse({"error": "Name must be 25 ASCII characters max."}, status=400)
        return http.JsonResponse({"id": recipe.pk, "name": recipe.name})


class RecipeDetail(generic.View):
    """
    Return every setting of one recipe, with its collections and version line.

    :raises Http404: if no recipe with the given ID exists.
    """

    def post(self, request: http.HttpRequest, recipe_id: int) -> http.HttpResponse:
        """Edit a recipe. The body holds the form fields that change."""
        recipe = shortcuts.get_object_or_404(models.FujifilmRecipe, pk=recipe_id)
        try:
            body = _json_object(request)
        except _InvalidParameter as error:
            return _bad_request(str(error))
        form = interface_forms.CreateRecipe(data={**_stored_form_values(recipe), **body})
        if not form.is_valid():
            return _form_response(form)
        try:
            update_recipe_uc.update_recipe_manually(
                recipe=recipe, data=recipe_views.recipe_data_from_form(form.cleaned_data)
            )
        except update_recipe_uc.RecipeCannotBeEditedError:
            return _bad_request(
                "This recipe's settings cannot be changed because it has associated images. "
                "You can still edit the name."
            )
        except update_recipe_uc.RecipeAlreadyExistsError:
            return _bad_request("A recipe with these settings already exists.")
        except update_recipe_uc.InvalidRecipeDataError as error:
            return _bad_request(f"{error.field} has an invalid value.")
        return http.JsonResponse({"id": recipe.pk})

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
            "is_favorite": recipe.id in recipe_queries.get_favorite_recipe_ids(recipe_ids=[recipe.id]),
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

    def post(self, request: http.HttpRequest) -> http.HttpResponse:
        """Create a collection from ``name`` and ``recipe_ids``."""
        try:
            name, recipe_ids = _collection_fields(request)
        except _InvalidParameter as error:
            return _bad_request(str(error))
        try:
            result = create_collection_uc.create_collection(name=name, recipe_ids=recipe_ids)
        except create_collection_uc.CollectionNameTaken:
            return _bad_request(_COLLECTION_NAME_TAKEN)
        except create_collection_uc.RecipeNotFound:
            return _bad_request(_COLLECTION_RECIPE_GONE)
        return http.JsonResponse({"id": result.collection_id}, status=201)

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


class CollectionRemove(generic.View):
    """
    Delete a collection. Its recipes stay in the library.

    :raises Http404: if no collection with the given ID exists.
    """

    def post(self, request: http.HttpRequest, collection_id: int) -> http.HttpResponse:
        try:
            delete_collection_uc.delete_collection(collection_id=collection_id)
        except delete_collection_uc.CollectionNotFound:
            raise http.Http404
        return http.JsonResponse({"removed": collection_id})


class CollectionDetail(generic.View):
    """
    Return one collection with its recipes in stored order.

    :raises Http404: if no collection with the given ID exists.
    """

    def post(self, request: http.HttpRequest, collection_id: int) -> http.HttpResponse:
        """Replace the collection's name and recipes. Order is kept as sent."""
        try:
            name, recipe_ids = _collection_fields(request)
        except _InvalidParameter as error:
            return _bad_request(str(error))
        try:
            update_collection_uc.update_collection(collection_id=collection_id, name=name, recipe_ids=recipe_ids)
        except update_collection_uc.CollectionNotFound:
            raise http.Http404
        except update_collection_uc.CollectionNameTaken:
            return _bad_request(_COLLECTION_NAME_TAKEN)
        except update_collection_uc.RecipeNotFound:
            return _bad_request(_COLLECTION_RECIPE_GONE)
        return http.JsonResponse({"id": collection_id})

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
