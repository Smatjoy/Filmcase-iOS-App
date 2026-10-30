"""
Record real /api/v1/ responses as JSON fixtures for the FilmcaseKit tests.

Not part of the normal suite (that is collected from tests/ only), and it refuses
to do anything unless RECORD_API_FIXTURES=1 is set. Run explicitly from the repo root:

    RECORD_API_FIXTURES=1 .venv/bin/pytest \
        ios/FilmcaseKit/Tests/FilmcaseKitTests/API/Fixtures/record_api_fixtures.py \
        -p no:cacheprovider

Drives Django's test client with the repo's factories against the test database.
Row ids depend on database sequences, so re-recording changes ids; the Swift tests
read ids from the fixtures rather than hard-coding them.
"""
import json
import os
from pathlib import Path

import pytest

from src.data.models import Sensor
from tests.factories import (
    ImageFactory,
    FujifilmRecipeFactory,
    RecipeCollectionFactory,
    RecipeCollectionMemberFactory,
    RecipeGroupFactory,
    RecipeGroupMemberFactory,
)

OUT = Path(__file__).resolve().parent
TOKEN = "fixture-token"
AUTH = {"HTTP_AUTHORIZATION": f"Bearer {TOKEN}"}

pytestmark = pytest.mark.skipif(
    os.environ.get("RECORD_API_FIXTURES") != "1",
    reason="set RECORD_API_FIXTURES=1 to (re)record the API fixtures",
)


def _write(name: str, response, *, status: int) -> None:
    assert response.status_code == status, (name, response.status_code)
    body = json.loads(response.content)
    (OUT / name).write_text(json.dumps(body, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


@pytest.mark.django_db
def test_record_api_fixtures(client, settings):
    settings.FILMCASE_API_TOKEN = TOKEN
    kw = dict(sharpness=0, high_iso_nr=0, clarity=0)
    classic = FujifilmRecipeFactory(
        name="Kodak Portra", film_simulation="Classic Chrome", dynamic_range="DR200",
        grain_roughness="Weak", grain_size="Small", color_chrome_effect="Strong",
        white_balance="Daylight", highlight=-1, shadow=1, color=2,
        **kw,
    )
    classic.sensors.set(Sensor.objects.filter(name="X-Trans V"))
    provia = FujifilmRecipeFactory(name="Plain Provia", film_simulation="Provia", **kw)
    ImageFactory(fujifilm_recipe=classic, is_favorite=True)
    line = RecipeGroupFactory()
    RecipeGroupMemberFactory(group=line, recipe=classic, position=1)
    RecipeGroupMemberFactory(group=line, recipe=provia, position=2)
    collection = RecipeCollectionFactory(name="Street")
    RecipeCollectionMemberFactory(group=collection, recipe=classic, position=0)
    RecipeCollectionMemberFactory(group=collection, recipe=provia, position=1)
    RecipeCollectionFactory(name="Empty")

    _write("recipe_list.json", client.get("/api/v1/recipes/", **AUTH), status=200)
    _write("recipe_list_favorites.json", client.get("/api/v1/recipes/", {"favorite": "true"}, **AUTH), status=200)
    _write("recipe_list_page2.json", client.get("/api/v1/recipes/", {"page_size": 1, "page": 2}, **AUTH), status=200)
    _write("recipe_detail.json", client.get(f"/api/v1/recipes/{classic.pk}/", **AUTH), status=200)
    _write("collection_list.json", client.get("/api/v1/collections/", **AUTH), status=200)
    _write("collection_detail.json", client.get(f"/api/v1/collections/{collection.pk}/", **AUTH), status=200)
    _write("camera_client_config.json", client.get("/api/v1/camera/client-config.json", **AUTH), status=200)
    _write("camera_payload.json", client.get(f"/api/v1/recipes/{classic.pk}/camera-payload.json", **AUTH), status=200)
    _write("error_401.json", client.get("/api/v1/recipes/"), status=401)
    _write("error_404.json", client.get("/api/v1/recipes/999999/", **AUTH), status=404)
    _write("error_400.json", client.get("/api/v1/recipes/", {"page": "x"}, **AUTH), status=400)
    settings.FILMCASE_API_TOKEN = ""
    _write("error_503.json", client.get("/api/v1/recipes/", **AUTH), status=503)
