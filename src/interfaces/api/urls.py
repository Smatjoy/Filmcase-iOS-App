from django.urls import path, re_path

from src.interfaces.api import auth, views
from src.interfaces.camera import views as camera_views

# The two camera routes reuse the browser's views unchanged, so their bodies are
# the same bytes; only the token check in front of them is new.
urlpatterns = [
    path("api/v1/recipes/", auth.api_view(views.RecipeList.as_view()), name="api-recipes"),
    path("api/v1/recipes/<int:recipe_id>/", auth.api_view(views.RecipeDetail.as_view()), name="api-recipe-detail"),
    path("api/v1/recipes/<int:recipe_id>/camera-payload.json", auth.api_view(camera_views.RecipeCameraPayload.as_view()), name="api-recipe-camera-payload"),
    path("api/v1/collections/", auth.api_view(views.CollectionList.as_view()), name="api-collections"),
    path("api/v1/collections/<int:collection_id>/", auth.api_view(views.CollectionDetail.as_view()), name="api-collection-detail"),
    path("api/v1/images/<int:image_id>/thumbnail", auth.api_view(views.ImageThumbnail.as_view()), name="api-image-thumbnail"),
    path("api/v1/images/<int:image_id>/file", auth.api_view(views.ImageFile.as_view()), name="api-image-file"),
    path("api/v1/camera/client-config.json", auth.api_view(camera_views.CameraClientConfig.as_view()), name="api-camera-client-config"),
    # Anything else under /api/ still has to meet the token check, so an unknown
    # path cannot be told apart from a known one without it.
    re_path(r"^api(?:/.*)?$", auth.api_view(views.NotFound.as_view()), name="api-not-found"),
]
