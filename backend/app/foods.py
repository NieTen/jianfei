import uuid

import httpx

from .models import FoodPayload


class FoodService:
    def __init__(self, settings, records):
        self.settings = settings
        self.records = records

    async def search(self, actor, query, external=False):
        local = self.records.food_search(actor, query)
        items = [{"name": row["payload"]["name"], "food": row["payload"]["food"], "source": "personal"} for row in local]
        if not external or not self.settings.food_api_key or not query.strip():
            return {"items": items, "external_available": bool(self.settings.food_api_key)}
        async with httpx.AsyncClient(timeout=20, follow_redirects=False) as client:
            response = await client.get(
                "https://api.nal.usda.gov/fdc/v1/foods/search",
                params={"api_key": self.settings.food_api_key, "query": query, "pageSize": 20},
            )
            response.raise_for_status()
            for food in response.json().get("foods", []):
                nutrients = {entry.get("nutrientId"): entry.get("value") for entry in food.get("foodNutrients", [])}
                value = FoodPayload(
                    id=str(uuid.uuid4()), name=food["description"], amount=100, basis_amount=100,
                    basis_kcal=nutrients.get(1008), basis_protein_g=nutrients.get(1003),
                    basis_carbs_g=nutrients.get(1005), basis_fat_g=nutrients.get(1004),
                    source="nutrition_database", uncertainty_note="USDA FoodData Central，每 100g 参考值",
                )
                items.append({"name": value.name, "food": value.model_dump(), "source": "USDA",
                              "source_id": str(food["fdcId"])})
        return {"items": items, "external_available": True}

