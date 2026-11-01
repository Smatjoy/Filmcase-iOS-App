import json
from pathlib import Path

import pytest
from django.test import override_settings

from tests.factories import (
    FujifilmRecipeFactory,
    ImageFactory,
    RecipeCollectionFactory,
    RecipeCollectionMemberFactory,
    RecipeGroupFactory,
    RecipeGroupMemberFactory,
)

FIXTURE_IMAGE = Path(__file__).resolve().parent.parent / "fixtures" / "images" / "XS107114.JPG"

TOKEN = "s3cret-token"
AUTH = {"HTTP_AUTHORIZATION": f"Bearer {TOKEN}"}


@pytest.fixture(autouse=True)
def _api_token(settings):
    settings.FILMCASE_API_TOKEN = TOKEN


def _get(client, url, **params):
    return client.get(url, params, **AUTH)


def _camera_recipe(**kwargs):
    return FujifilmRecipeFactory(sharpness=0, high_iso_nr=0, clarity=0, **kwargs)


# Every route the API serves, with a callable that creates what it needs and returns the URL.
def _recipes_url():
    return "/api/v1/recipes/"


def _recipe_detail_url():
    return f"/api/v1/recipes/{_camera_recipe(name='Auth Probe').pk}/"


def _collections_url():
    return "/api/v1/collections/"


def _collection_detail_url():
    return f"/api/v1/collections/{RecipeCollectionFactory().pk}/"


def _thumbnail_url():
    return f"/api/v1/images/{ImageFactory(filepath=str(FIXTURE_IMAGE)).pk}/thumbnail"


def _client_config_url():
    return "/api/v1/camera/client-config.json"


def _camera_payload_url():
    return f"/api/v1/recipes/{_camera_recipe(name='Auth Probe').pk}/camera-payload.json"


ALL_ROUTES = [
    _recipes_url,
    _recipe_detail_url,
    _collections_url,
    _collection_detail_url,
    _thumbnail_url,
    _client_config_url,
    _camera_payload_url,
]


@pytest.mark.django_db
@pytest.mark.parametrize("make_url", ALL_ROUTES)
class TestAuthentication:
    def test_200_with_the_token(self, client, make_url, tmp_path):
        url = make_url()

        with override_settings(THUMBNAIL_CACHE_DIR=tmp_path):
            response = client.get(url, **AUTH)

        assert response.status_code == 200

    def test_401_without_a_token(self, client, make_url):
        response = client.get(make_url())

        assert response.status_code == 401
        assert response["WWW-Authenticate"] == "Bearer"
        assert response["Content-Type"] == "application/json"

    def test_401_with_a_wrong_token(self, client, make_url):
        response = client.get(make_url(), HTTP_AUTHORIZATION="Bearer nope")

        assert response.status_code == 401
        assert response["WWW-Authenticate"] == "Bearer"

    def test_401_with_a_non_bearer_scheme(self, client, make_url):
        response = client.get(make_url(), HTTP_AUTHORIZATION=f"Basic {TOKEN}")

        assert response.status_code == 401

    def test_200_without_a_token_when_none_is_configured(self, client, make_url, settings, tmp_path):
        settings.FILMCASE_API_TOKEN = ""

        with override_settings(THUMBNAIL_CACHE_DIR=tmp_path):
            response = client.get(make_url())

        assert response.status_code == 200

    def test_a_sent_token_is_ignored_when_none_is_configured(self, client, make_url, settings, tmp_path):
        settings.FILMCASE_API_TOKEN = ""

        with override_settings(THUMBNAIL_CACHE_DIR=tmp_path):
            response = client.get(make_url(), HTTP_AUTHORIZATION="Bearer anything")

        assert response.status_code == 200

    def test_405_without_a_token_when_none_is_configured(self, client, make_url, settings):
        settings.FILMCASE_API_TOKEN = ""

        assert client.post(make_url()).status_code == 405

    def test_405_for_anything_but_get(self, client, make_url):
        response = client.post(make_url(), **AUTH)

        assert response.status_code == 405
        assert response["Allow"] == "GET, HEAD"
        assert response["Content-Type"] == "application/json"


@pytest.mark.django_db
class TestOutsideTheApiPrefix:
    def test_html_routes_stay_unauthenticated(self, client):
        assert client.get("/recipes/").status_code == 200

    def test_camera_json_routes_stay_unauthenticated(self, client):
        recipe = _camera_recipe(name="Open Route")

        assert client.get("/camera/client-config.json").status_code == 200
        assert client.get(f"/recipes/{recipe.pk}/camera-payload.json").status_code == 200

    def test_unknown_api_paths_are_json_404_with_the_token(self, client):
        response = client.get("/api/v1/nope/", **AUTH)

        assert response.status_code == 404
        assert response["Content-Type"] == "application/json"

    def test_unknown_api_paths_require_the_token_too(self, client):
        assert client.get("/api/v1/nope/").status_code == 401

    def test_unknown_api_paths_are_json_404_when_unset(self, client, settings):
        settings.FILMCASE_API_TOKEN = ""

        response = client.get("/api/v1/nope/")

        assert response.status_code == 404
        assert response["Content-Type"] == "application/json"


@pytest.mark.django_db
class TestRecipeList:
    def test_lists_recipes_with_summary_fields(self, client):
        recipe = _camera_recipe(name="Kodak Portra", film_simulation="Classic Chrome")

        payload = json.loads(_get(client, "/api/v1/recipes/").content)

        assert payload["count"] == 1
        assert payload["next"] is None
        assert payload["previous"] is None
        item = payload["results"][0]
        assert item["id"] == recipe.pk
        assert item["name"] == "Kodak Portra"
        assert item["film_simulation"] == "Classic Chrome"
        assert item["version"] is None
        assert item["cover_thumbnail_url"] is None

    def test_cover_thumbnail_url_points_under_api(self, client):
        recipe = _camera_recipe(name="Covered")
        image = ImageFactory(fujifilm_recipe=recipe)

        item = json.loads(_get(client, "/api/v1/recipes/").content)["results"][0]

        assert item["cover_thumbnail_url"] == f"/api/v1/images/{image.pk}/thumbnail"

    def test_includes_version_info(self, client):
        recipe = _camera_recipe(name="Versioned")
        RecipeGroupMemberFactory(group=RecipeGroupFactory(), recipe=recipe, position=2)

        item = json.loads(_get(client, "/api/v1/recipes/").content)["results"][0]

        assert item["version"] == {"position": 2, "label": "v2"}

    def test_paginates(self, client):
        for n in range(5):
            _camera_recipe(name=f"Recipe {n}")

        first = json.loads(_get(client, "/api/v1/recipes/", page_size=2).content)
        last = json.loads(_get(client, "/api/v1/recipes/", page_size=2, page=3).content)

        assert first["count"] == 5
        assert len(first["results"]) == 2
        assert first["previous"] is None
        assert first["next"] == "/api/v1/recipes/?page_size=2&page=2"
        assert len(last["results"]) == 1
        assert last["next"] is None
        assert last["previous"] == "/api/v1/recipes/?page_size=2&page=2"

    def test_pages_do_not_overlap(self, client):
        for n in range(4):
            _camera_recipe(name=f"Recipe {n}")

        page_1 = json.loads(_get(client, "/api/v1/recipes/", page_size=2).content)["results"]
        page_2 = json.loads(_get(client, "/api/v1/recipes/", page_size=2, page=2).content)["results"]

        assert {r["id"] for r in page_1}.isdisjoint({r["id"] for r in page_2})

    @pytest.mark.parametrize("params", [{"page_size": 101}, {"page_size": 0}, {"page_size": "x"}, {"page": 0}, {"page": "x"}])
    def test_400_for_invalid_pagination(self, client, params):
        response = _get(client, "/api/v1/recipes/", **params)

        assert response.status_code == 400
        assert "error" in json.loads(response.content)

    def test_page_size_can_be_the_maximum(self, client):
        assert _get(client, "/api/v1/recipes/", page_size=100).status_code == 200

    def test_recipe_with_a_favourite_image_is_a_favourite(self, client):
        loved = _camera_recipe(name="Loved")
        ImageFactory(fujifilm_recipe=loved, is_favorite=True)
        ImageFactory(fujifilm_recipe=loved, is_favorite=False)
        plain = _camera_recipe(name="Plain")
        ImageFactory(fujifilm_recipe=plain, is_favorite=False)

        results = json.loads(_get(client, "/api/v1/recipes/").content)["results"]

        assert {r["name"]: r["is_favorite"] for r in results} == {"Loved": True, "Plain": False}

    @pytest.mark.parametrize("value", ["true", "1"])
    def test_filters_by_favorite(self, client, value):
        loved = _camera_recipe(name="Loved")
        ImageFactory(fujifilm_recipe=loved, is_favorite=True)
        ImageFactory(fujifilm_recipe=loved, is_favorite=True)
        _camera_recipe(name="Plain")

        payload = json.loads(_get(client, "/api/v1/recipes/", favorite=value).content)

        assert [r["name"] for r in payload["results"]] == ["Loved"]
        assert payload["count"] == 1

    def test_favorite_filter_combines_with_facets(self, client):
        chrome = _camera_recipe(name="Chrome", film_simulation="Classic Chrome")
        ImageFactory(fujifilm_recipe=chrome, is_favorite=True)
        provia = _camera_recipe(name="Provia One", film_simulation="Provia")
        ImageFactory(fujifilm_recipe=provia, is_favorite=True)

        payload = json.loads(_get(client, "/api/v1/recipes/", favorite="true", film_simulation="Provia").content)

        assert [r["name"] for r in payload["results"]] == ["Provia One"]

    def test_filters_by_film_simulation(self, client):
        _camera_recipe(name="Chrome", film_simulation="Classic Chrome")
        _camera_recipe(name="Provia One", film_simulation="Provia")

        payload = json.loads(_get(client, "/api/v1/recipes/", film_simulation="Classic Chrome").content)

        assert [r["name"] for r in payload["results"]] == ["Chrome"]
        assert payload["count"] == 1

    def test_filters_by_several_values_of_one_facet(self, client):
        _camera_recipe(name="Chrome", film_simulation="Classic Chrome")
        _camera_recipe(name="Provia One", film_simulation="Provia")
        _camera_recipe(name="Velvia One", film_simulation="Velvia")

        response = client.get("/api/v1/recipes/?film_simulation=Provia&film_simulation=Velvia", **AUTH)

        assert {r["name"] for r in json.loads(response.content)["results"]} == {"Provia One", "Velvia One"}

    def test_filters_combine_across_facets(self, client):
        _camera_recipe(name="Match", film_simulation="Provia", grain_roughness="Strong")
        _camera_recipe(name="Wrong grain", film_simulation="Provia", grain_roughness="Off")
        _camera_recipe(name="Wrong sim", film_simulation="Velvia", grain_roughness="Strong")

        payload = json.loads(
            _get(client, "/api/v1/recipes/", film_simulation="Provia", grain_roughness="Strong").content
        )

        assert [r["name"] for r in payload["results"]] == ["Match"]

    def test_filters_by_name_search(self, client):
        _camera_recipe(name="Street Mono")
        _camera_recipe(name="Golden Hour")

        payload = json.loads(_get(client, "/api/v1/recipes/", name_search="golden").content)

        assert [r["name"] for r in payload["results"]] == ["Golden Hour"]

    def test_filters_are_kept_in_the_next_link(self, client):
        for n in range(3):
            _camera_recipe(name=f"Recipe {n}", film_simulation="Provia")

        payload = json.loads(_get(client, "/api/v1/recipes/", page_size=2, film_simulation="Provia").content)

        assert "film_simulation=Provia" in payload["next"]

    def test_returns_the_facet_options(self, client):
        _camera_recipe(name="Chrome", film_simulation="Classic Chrome")

        facets = json.loads(_get(client, "/api/v1/recipes/").content)["facets"]

        assert facets["film_simulation"]["options"][0]["value"] == "Classic Chrome"


@pytest.mark.django_db
class TestRecipeDetail:
    @pytest.mark.parametrize("favorite_image, expected", [(True, True), (False, False)])
    def test_is_favorite_follows_its_images(self, client, favorite_image, expected):
        recipe = _camera_recipe(name="Detail")
        ImageFactory(fujifilm_recipe=recipe, is_favorite=favorite_image)

        payload = json.loads(_get(client, f"/api/v1/recipes/{recipe.pk}/").content)

        assert payload["is_favorite"] is expected

    def test_returns_every_setting(self, client):
        recipe = FujifilmRecipeFactory(
            name="Full",
            film_simulation="Classic Chrome",
            white_balance="Kelvin",
            white_balance_red=2,
            white_balance_blue=-3,
            highlight=1.5,
            shadow=-1,
            color=2,
            sharpness=0,
            high_iso_nr=-2,
            clarity=1,
            description="Warm and soft",
        )

        payload = json.loads(_get(client, f"/api/v1/recipes/{recipe.pk}/").content)

        assert payload["id"] == recipe.pk
        assert payload["name"] == "Full"
        assert payload["description"] == "Warm and soft"
        assert payload["film_simulation"] == "Classic Chrome"
        assert payload["white_balance"] == "Kelvin"
        assert payload["white_balance_red"] == 2
        assert payload["white_balance_blue"] == -3
        assert payload["highlight"] == 1.5
        assert payload["shadow"] == -1
        assert payload["high_iso_nr"] == -2
        assert payload["monochromatic_color_warm_cool"] is None

    def test_includes_collections_and_version_line(self, client):
        recipe = _camera_recipe(name="Member")
        sibling = _camera_recipe(name="Sibling")
        line = RecipeGroupFactory()
        RecipeGroupMemberFactory(group=line, recipe=sibling, position=1)
        RecipeGroupMemberFactory(group=line, recipe=recipe, position=2)
        collection = RecipeCollectionFactory(name="Street")
        RecipeCollectionMemberFactory(group=collection, recipe=recipe)

        payload = json.loads(_get(client, f"/api/v1/recipes/{recipe.pk}/").content)

        assert payload["collections"] == [{"id": collection.pk, "name": "Street", "recipe_count": 1}]
        assert payload["version"] == {"position": 2, "label": "v2"}
        assert [(v["id"], v["is_current"]) for v in payload["version_line"]] == [(sibling.pk, False), (recipe.pk, True)]

    def test_cover_image_urls(self, client):
        recipe = _camera_recipe(name="Covered")
        image = ImageFactory(fujifilm_recipe=recipe)

        payload = json.loads(_get(client, f"/api/v1/recipes/{recipe.pk}/").content)

        assert payload["cover_image_url"] == f"/api/v1/images/{image.pk}/file"
        assert payload["cover_thumbnail_url"] == f"/api/v1/images/{image.pk}/thumbnail"
        assert payload["camera_payload_url"] == f"/api/v1/recipes/{recipe.pk}/camera-payload.json"

    def test_no_cover_means_null_urls(self, client):
        recipe = _camera_recipe(name="Bare")

        payload = json.loads(_get(client, f"/api/v1/recipes/{recipe.pk}/").content)

        assert payload["cover_image_url"] is None
        assert payload["cover_thumbnail_url"] is None
        assert payload["version"] is None
        assert payload["version_line"] == []

    def test_404_json_for_an_unknown_recipe(self, client):
        response = _get(client, "/api/v1/recipes/99999/")

        assert response.status_code == 404
        assert response["Content-Type"] == "application/json"


@pytest.mark.django_db
class TestCollections:
    def test_lists_collections(self, client):
        group = RecipeCollectionFactory(name="Street Mono")
        RecipeCollectionMemberFactory(group=group, recipe=_camera_recipe(name="Tri-X", film_simulation="Acros"))

        payload = json.loads(_get(client, "/api/v1/collections/").content)

        assert payload["count"] == 1
        assert payload["results"][0] == {
            "id": group.pk,
            "name": "Street Mono",
            "recipe_count": 1,
            "film_simulations": ["Acros"],
            "cover_thumbnail_urls": [],
        }

    def test_mosaic_images_become_thumbnail_urls(self, client):
        group = RecipeCollectionFactory(name="Shot")
        recipe = _camera_recipe(name="Has Image")
        image = ImageFactory(fujifilm_recipe=recipe)
        RecipeCollectionMemberFactory(group=group, recipe=recipe)

        payload = json.loads(_get(client, "/api/v1/collections/").content)

        assert payload["results"][0]["cover_thumbnail_urls"] == [f"/api/v1/images/{image.pk}/thumbnail"]

    def test_filters_by_name(self, client):
        RecipeCollectionFactory(name="Street Mono")
        RecipeCollectionFactory(name="Golden Hour")

        payload = json.loads(_get(client, "/api/v1/collections/", name_search="golden").content)

        assert [c["name"] for c in payload["results"]] == ["Golden Hour"]

    def test_filters_by_film_simulation(self, client):
        mono = RecipeCollectionFactory(name="Mono")
        RecipeCollectionMemberFactory(group=mono, recipe=_camera_recipe(film_simulation="Acros"))
        color = RecipeCollectionFactory(name="Color")
        RecipeCollectionMemberFactory(group=color, recipe=_camera_recipe(film_simulation="Velvia"))

        payload = json.loads(_get(client, "/api/v1/collections/", film_simulation="Acros").content)

        assert [c["name"] for c in payload["results"]] == ["Mono"]

    def test_detail_lists_recipes_in_stored_order(self, client):
        group = RecipeCollectionFactory(name="Ordered")
        second = _camera_recipe(name="Second")
        first = _camera_recipe(name="First")
        RecipeCollectionMemberFactory(group=group, recipe=first, position=0)
        RecipeCollectionMemberFactory(group=group, recipe=second, position=1)

        payload = json.loads(_get(client, f"/api/v1/collections/{group.pk}/").content)

        assert payload["name"] == "Ordered"
        assert payload["recipe_ids"] == [first.pk, second.pk]
        assert [r["name"] for r in payload["recipes"]] == ["First", "Second"]
        assert payload["recipes"][0]["film_simulation"] == "Provia"

    def test_detail_404_json_for_an_unknown_collection(self, client):
        response = _get(client, "/api/v1/collections/99999/")

        assert response.status_code == 404
        assert response["Content-Type"] == "application/json"

    def test_detail_404_for_a_version_line_group(self, client):
        group = RecipeGroupFactory()

        assert _get(client, f"/api/v1/collections/{group.pk}/").status_code == 404


@pytest.mark.django_db
class TestImages:
    def test_thumbnail_is_the_resized_image(self, client, tmp_path):
        image = ImageFactory(filepath=str(FIXTURE_IMAGE))

        with override_settings(THUMBNAIL_CACHE_DIR=tmp_path):
            api = client.get(f"/api/v1/images/{image.pk}/thumbnail", **AUTH)
            browser = client.get(f"/images/file/{image.pk}/", {"width": "600"})

        assert api.status_code == 200
        assert api["Content-Type"].startswith("image/")
        assert b"".join(api.streaming_content) == b"".join(browser.streaming_content)

    def test_file_is_the_original_image(self, client):
        image = ImageFactory(filepath=str(FIXTURE_IMAGE))

        response = client.get(f"/api/v1/images/{image.pk}/file", **AUTH)

        assert b"".join(response.streaming_content) == FIXTURE_IMAGE.read_bytes()

    def test_thumbnail_404_json_for_an_unknown_image(self, client):
        response = client.get("/api/v1/images/99999/thumbnail", **AUTH)

        assert response.status_code == 404
        assert response["Content-Type"] == "application/json"

    def test_thumbnail_404_when_the_file_is_missing_on_disk(self, client):
        image = ImageFactory(filepath="/nonexistent/ghost.JPG")

        assert client.get(f"/api/v1/images/{image.pk}/thumbnail", **AUTH).status_code == 404

    def test_file_401_without_a_token(self, client):
        image = ImageFactory(filepath=str(FIXTURE_IMAGE))

        assert client.get(f"/api/v1/images/{image.pk}/file").status_code == 401


@pytest.mark.django_db
class TestCameraJsonMirror:
    def test_client_config_matches_the_browser_route_byte_for_byte(self, client):
        api = client.get("/api/v1/camera/client-config.json", **AUTH)
        browser = client.get("/camera/client-config.json")

        assert api.status_code == 200
        assert api.content == browser.content
        assert api["Content-Type"] == browser["Content-Type"]
        assert api["Cache-Control"] == "no-store"

    def test_recipe_payload_matches_the_browser_route_byte_for_byte(self, client):
        recipe = _camera_recipe(name="Mirrored")

        api = client.get(f"/api/v1/recipes/{recipe.pk}/camera-payload.json", **AUTH)
        browser = client.get(f"/recipes/{recipe.pk}/camera-payload.json")

        assert api.status_code == 200
        assert api.content == browser.content
        assert api["Cache-Control"] == "no-store"

    def test_recipe_payload_404_json_for_an_unknown_recipe(self, client):
        response = client.get("/api/v1/recipes/99999/camera-payload.json", **AUTH)

        assert response.status_code == 404
        assert response["Content-Type"] == "application/json"

    def test_recipe_payload_404_for_an_unnamed_recipe(self, client):
        recipe = _camera_recipe(name="")

        assert client.get(f"/api/v1/recipes/{recipe.pk}/camera-payload.json", **AUTH).status_code == 404

    def test_unknown_recipe_is_not_revealed_without_the_token(self, client):
        assert client.get("/api/v1/recipes/99999/camera-payload.json").status_code == 401
