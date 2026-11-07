from datetime import date
from typing import Any, Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class InputModel(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class Registration(InputModel):
    username: str = Field(min_length=3, max_length=64, pattern=r"^[a-zA-Z0-9_.-]+$")
    password: str = Field(min_length=10, max_length=128)
    display_name: str = Field(min_length=1, max_length=40)
    # 兼容旧客户端提交的字段，新版注册不再要求或验证开户凭据。
    bootstrap_code: str | None = None
    device_id: str = Field(min_length=8, max_length=80)
    device_name: str = Field(default="我的 iPhone", max_length=80)


class Login(InputModel):
    username: str
    password: str
    device_id: str = Field(min_length=8, max_length=80)
    device_name: str = Field(default="我的 iPhone", max_length=80)


class RefreshRequest(InputModel):
    refresh_token: str


class RecoveryRequest(InputModel):
    username: str
    recovery_code: str
    new_password: str = Field(min_length=10, max_length=128)


class DeviceAction(InputModel):
    device_id: str


class IdentityBinding(InputModel):
    local_user_id: str


class ProfilePayload(InputModel):
    display_name: str = ""
    birth_date: str | None = None
    age: int | None = Field(default=None, ge=1, le=120)
    sex_for_formula: Literal["male", "female", "unspecified"] = "unspecified"
    height_cm: float | None = Field(default=None, gt=0, le=300)
    activity_factor: float = Field(default=1.2, ge=1, le=2.5)
    step_length_m: float | None = Field(default=None, gt=0, le=2)
    timezone: str = "Asia/Shanghai"
    day_start_minutes: int = Field(default=0, ge=0, lt=1440)
    weight_unit: Literal["kg", "lb"] = "kg"
    energy_unit: Literal["kcal", "kJ"] = "kcal"
    height_unit: Literal["cm", "ft-in"] = "cm"
    routine_meals: list[str] = Field(default_factory=lambda: ["breakfast", "lunch", "dinner"], min_length=1, max_length=8)
    recording_only: bool = False
    effective_at: str | None = None

    @field_validator("timezone")
    @classmethod
    def valid_timezone(cls, value):
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError:
            raise ValueError("统计时区无效")
        return value

    @field_validator("birth_date")
    @classmethod
    def valid_birthday(cls, value):
        if value is not None and date.fromisoformat(value) > date.today():
            raise ValueError("出生日期不能晚于今天")
        return value


class WeightPayload(InputModel):
    measured_at: str
    weight_kg: float = Field(gt=0, le=600)
    source: str = "manual"
    source_id: str | None = None
    source_name: str | None = None
    note: str = Field(default="", max_length=2000)
    hidden: bool = False
    source_deleted: bool = False
    corrected_weight_kg: float | None = Field(default=None, gt=0, le=600)
    representative: bool = False


class FoodPayload(InputModel):
    id: str
    name: str = Field(min_length=1, max_length=200)
    amount: float = Field(gt=0, le=100000)
    unit: Literal["g", "ml", "serving"] = "g"
    basis_amount: float = Field(default=100, gt=0)
    nutrition_basis: Literal["per_100g", "per_100ml", "per_serving", "total"] = "per_100g"
    basis_kcal: float | None = Field(default=None, ge=0, le=100000)
    basis_protein_g: float | None = Field(default=None, ge=0, le=100000)
    basis_carbs_g: float | None = Field(default=None, ge=0, le=100000)
    basis_fat_g: float | None = Field(default=None, ge=0, le=100000)
    consumed_fraction: float = Field(default=1, ge=0, le=1)
    source: str = "manual"
    confidence: float | None = Field(default=None, ge=0, le=1)
    uncertainty_note: str = ""
    food_state: str = "unknown"
    serving_weight_g: float | None = Field(default=None, gt=0)
    density_g_ml: float | None = Field(default=None, gt=0)
    locked_values: dict[str, float] = Field(default_factory=dict)
    evidence_photo_ids: list[str] = Field(default_factory=list)
    requires_portion: bool = False


class MealPayload(InputModel):
    eaten_at: str
    timezone: str = "Asia/Shanghai"
    meal_type: str = "lunch"
    status: Literal["draft", "confirmed", "skipped"] = "draft"
    items: list[FoodPayload] = Field(default_factory=list, max_length=100)
    photo_ids: list[str] = Field(default_factory=list, max_length=6)
    note: str = Field(default="", max_length=2000)
    ai_result: dict[str, Any] | None = None
    ai_task_id: str | None = None
    sync_photos: bool = True

    @model_validator(mode="after")
    def valid_items(self):
        if self.status == "confirmed" and not self.items:
            raise ValueError("已确认餐次至少需要一个食物")
        if self.status == "confirmed" and any(item.requires_portion for item in self.items):
            raise ValueError("请先确认候选食物的实际份量")
        if self.status == "skipped" and self.items:
            raise ValueError("未进食餐次不能同时包含食物")
        return self


class AIResultItem(InputModel):
    name: str = Field(min_length=1, max_length=200)
    estimated_weight_g: float | None = Field(default=None, gt=0, le=100000)
    calories_kcal: float | None = Field(default=None, ge=0, le=100000)
    protein_g: float | None = Field(default=None, ge=0, le=100000)
    carbs_g: float | None = Field(default=None, ge=0, le=100000)
    fat_g: float | None = Field(default=None, ge=0, le=100000)
    confidence: float | None = Field(default=None, ge=0, le=1)
    food_state: str = "unknown"
    evidence_photo_ids: list[str] = Field(default_factory=list, max_length=6)


class AIRecognitionOutput(InputModel):
    items: list[AIResultItem] = Field(max_length=100)
    uncertainty_note: str = Field(default="", max_length=4000)


class DailyStatusPayload(InputModel):
    timezone: str = "Asia/Shanghai"
    routine_meals: list[str] = Field(default_factory=lambda: ["breakfast", "lunch", "dinner"])
    intake_complete: bool = False
    checked_in: bool = False
    confirmed_at: str | None = None


class GoalPayload(InputModel):
    target_weight_kg: float | None = Field(default=None, gt=0, le=600)
    step_goal: int = Field(default=8000, ge=1, le=200000)
    start_date: str
    end_date: str
    selected_items: list[Literal["diet", "weight", "steps"]] = Field(default_factory=lambda: ["diet", "weight", "steps"])

    @model_validator(mode="after")
    def chronological(self):
        if date.fromisoformat(self.end_date) < date.fromisoformat(self.start_date):
            raise ValueError("目标结束日期不能早于开始日期")
        return self


class HealthPayload(InputModel):
    timezone: str = "Asia/Shanghai"
    window_start: str
    window_end: str
    steps: float | None = Field(default=None, ge=0)
    active_kcal: float | None = Field(default=None, ge=0)
    resting_kcal: float | None = Field(default=None, ge=0)
    resting_coverage: float | None = Field(default=None, ge=0, le=1)
    heart_rate: float | None = Field(default=None, gt=0)
    resting_heart_rate: float | None = Field(default=None, gt=0)
    sleep_hours: float | None = Field(default=None, ge=0, le=30)
    body_fat_percent: float | None = Field(default=None, ge=0, le=100)
    workout_minutes: float | None = Field(default=None, ge=0)
    distance_km: float | None = Field(default=None, ge=0)
    source: str = "healthkit"
    updated_at: str


class MeasurementPayload(InputModel):
    measured_at: str
    waist_cm: float | None = Field(default=None, gt=0, le=400)
    hip_cm: float | None = Field(default=None, gt=0, le=400)
    body_fat_percent: float | None = Field(default=None, ge=0, le=100)
    muscle_kg: float | None = Field(default=None, gt=0, le=300)
    note: str = ""


class WorkoutPayload(InputModel):
    start_at: str
    end_at: str
    activity_type: str
    duration_minutes: float = Field(ge=0)
    energy_kcal: float | None = Field(default=None, ge=0)
    distance_km: float | None = Field(default=None, ge=0)
    source_id: str
    source_name: str = "健康"
    source_deleted: bool = False


class PreferencePayload(InputModel):
    food_name: str
    weight_multiplier: float = Field(default=1, gt=0, le=5)
    calorie_multiplier: float = Field(default=1, gt=0, le=5)
    sample_count: int = Field(default=1, ge=1)


class FavoritePayload(InputModel):
    name: str
    food: FoodPayload


KIND_MODELS = {
    "profile": ProfilePayload, "weight": WeightPayload, "meal": MealPayload,
    "daily_status": DailyStatusPayload, "goal": GoalPayload, "health_day": HealthPayload,
    "measurement": MeasurementPayload, "workout": WorkoutPayload,
    "food_preference": PreferencePayload, "favorite": FavoritePayload,
}


class Mutation(InputModel):
    change_id: str = Field(min_length=8, max_length=80)
    entity_id: str = Field(min_length=8, max_length=80)
    kind: str
    business_date: str
    payload: dict[str, Any]
    source_id: str | None = None
    base_version: int = Field(ge=0)
    deleted_at: str | None = None

    @field_validator("business_date")
    @classmethod
    def valid_date(cls, value):
        date.fromisoformat(value)
        return value

    @field_validator("kind")
    @classmethod
    def valid_kind(cls, value):
        if value not in KIND_MODELS:
            raise ValueError("不支持的记录类型")
        return value


class PushRequest(InputModel):
    epoch: str
    generation: int
    changes: list[Mutation] = Field(max_length=200)


class MediaInit(InputModel):
    id: str
    meal_id: str
    size: int = Field(gt=0, le=15 * 1024 * 1024)
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    mime_type: str = "image/jpeg"
    temporary: bool = False


class RecognitionRequest(InputModel):
    request_key: str
    meal_id: str
    meal_version: int = Field(ge=0)
    photo_ids: list[str] = Field(min_length=1, max_length=6)
    note: str = Field(default="", max_length=2000)
    allow_external: bool = False


class AISettingsRequest(InputModel):
    base_url: str = Field(min_length=1, max_length=2048)
    model: str = Field(default="", max_length=200)
    api_key: str | None = Field(default=None, max_length=4096)
    external: bool = True
    structured_output: bool = True
    max_output_tokens: int = Field(default=4096, ge=256, le=32768)


class ChallengeCreate(InputModel):
    title: str = Field(default="一起好好记录", min_length=1, max_length=80)
    timezone: str = "Asia/Shanghai"
    day_start_minutes: int = Field(default=0, ge=0, lt=1440)
    duration_days: int = Field(default=28, ge=1, le=365)
    max_members: int = Field(default=2, ge=2, le=8)
    goal: GoalPayload


class ChallengeJoin(InputModel):
    code: str
    goal: GoalPayload


class ChallengeConfirmation(InputModel):
    version: int


class ConsentRequest(InputModel):
    recipient_id: str
    scopes: list[Literal["checkin", "goal_progress", "weight_change", "steps", "weight", "meals", "photos", "notes", "score", "streak", "health", "profile"]]
    history_from: str
    expected_version: int = 0


class EncouragementRequest(InputModel):
    id: str
    message: str = Field(min_length=1, max_length=200)


class ExportRequest(InputModel):
    request_key: str
    password: str = Field(min_length=10, max_length=128)
    include_photos: bool = True
    format: Literal["archive", "csv"] = "archive"


class DeleteRequest(InputModel):
    password: str
    request_key: str
    receipt_secret: str | None = Field(default=None, min_length=32, max_length=128)


class PushRegistration(InputModel):
    token: str = Field(max_length=256)
    enabled: bool

