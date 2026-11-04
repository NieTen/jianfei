from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from zoneinfo import ZoneInfo


def number(value):
    return Decimal(str(value))


def rounded(value):
    return float(number(value).quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP))


def day_window(day, zone_name, start_minutes=0):
    zone = ZoneInfo(zone_name)
    local_day = date.fromisoformat(day) if isinstance(day, str) else day
    local_time = time(start_minutes // 60, start_minutes % 60)
    start = datetime.combine(local_day, local_time, zone)
    end = datetime.combine(local_day + timedelta(days=1), local_time, zone)
    return start.astimezone(timezone.utc), end.astimezone(timezone.utc)


def business_day(moment, zone_name, start_minutes=0):
    local = moment.astimezone(ZoneInfo(zone_name))
    day = local.date()
    if local.hour * 60 + local.minute < start_minutes:
        day -= timedelta(days=1)
    return day.isoformat()


def food_totals(food):
    ratio = number(food["amount"]) / number(food.get("basis_amount", 100))
    ratio *= number(food.get("consumed_fraction", 1))
    result = {}
    for field in ("kcal", "protein_g", "carbs_g", "fat_g"):
        locked = food.get("locked_values", {}).get(field)
        basis = food.get("basis_" + field)
        result[field] = rounded(locked) if locked is not None else rounded(number(basis) * ratio) if basis is not None else None
    return result


def basal_energy(profile, weight, day):
    if profile.get("recording_only") or weight is None or profile.get("height_cm") is None:
        return None
    age = profile.get("age")
    if profile.get("birth_date"):
        birthday = date.fromisoformat(profile["birth_date"])
        current = date.fromisoformat(day)
        age = current.year - birthday.year - ((current.month, current.day) < (birthday.month, birthday.day))
    sex = profile.get("sex_for_formula")
    if age is None or age < 18 or sex not in ("male", "female"):
        return None
    return rounded(number(weight) * 10 + number(profile["height_cm"]) * Decimal("6.25") - age * 5 + (5 if sex == "male" else -161))


def energy_summary(day, profile, weight, meals, health, completion, now=None):
    now = now or datetime.now(timezone.utc)
    start, end = day_window(day, profile.get("timezone", "Asia/Shanghai"), profile.get("day_start_minutes", 0))
    effective_end = min(end, now)
    elapsed = max(0, (effective_end - start).total_seconds())
    bmr = basal_energy(profile, weight, day)
    resting = health.get("resting_kcal")
    coverage = health.get("resting_coverage")
    method = "healthkit"
    if resting is None or coverage is None or coverage < 0.95:
        resting = rounded(number(bmr) * number(elapsed) / 86400) if bmr is not None else None
        method = "bmr_healthkit"
    active = health.get("active_kcal")
    if active is None and health.get("steps") is not None and weight is not None and profile.get("step_length_m"):
        active = rounded(number("0.5") * number(weight) * number(health["steps"]) * number(profile["step_length_m"]) / 1000)
        method = "walking_estimate"
    expenditure = rounded(number(resting) + number(active)) if resting is not None and active is not None else None
    if expenditure is None and now >= end and bmr is not None:
        expenditure = rounded(number(bmr) * number(elapsed) / 86400 * number(profile.get("activity_factor", 1.2)))
        method = "activity_factor"
    intake, macro_totals, missing = Decimal(0), {"protein_g": Decimal(0), "carbs_g": Decimal(0), "fat_g": Decimal(0)}, set()
    confirmed_types, pending, known_energy = set(), False, False
    for meal in meals:
        status = meal.get("status", "draft")
        eaten_at = datetime.fromisoformat(meal["eaten_at"].replace("Z", "+00:00"))
        if eaten_at > now:
            pending = True
            continue
        if status == "draft":
            pending = True
            continue
        confirmed_types.add(meal["meal_type"])
        known_energy = known_energy or status == "skipped"
        for food in meal.get("items", []):
            totals = food_totals(food)
            if totals["kcal"] is None:
                missing.add("kcal")
            else:
                intake += number(totals["kcal"])
                known_energy = True
            for field in macro_totals:
                if totals[field] is None:
                    missing.add(field)
                else:
                    macro_totals[field] += number(totals[field])
    routine = completion.get("routine_meals", profile.get("routine_meals", ["breakfast", "lunch", "dinner"]))
    unrecorded = [name for name in routine if name not in confirmed_types]
    complete = bool(completion.get("intake_complete")) and not pending and not unrecorded and "kcal" not in missing
    intake_value = rounded(intake) if known_energy else None
    deficit = rounded(number(expenditure) - intake) if expenditure is not None and intake_value is not None and "kcal" not in missing else None
    forecast = rounded(number(bmr) * number((end - start).total_seconds()) / 86400 * number(profile.get("activity_factor", 1.2))) if bmr is not None else None
    return {
        "date": day, "intake_kcal": intake_value, "expenditure_kcal": expenditure,
        "deficit_kcal": deficit, "forecast_kcal": forecast, "bmr": bmr,
        "resting_kcal": resting, "active_kcal": active, "method": method,
        "intake_complete": complete, "pending": pending, "unrecorded_meals": unrecorded,
        "missing_nutrients": sorted(missing),
        "macros": {key: rounded(value) if confirmed_types and key not in missing else None for key, value in macro_totals.items()},
        "completeness_score": round(100 * len(confirmed_types.intersection(routine)) / max(1, len(routine))),
        "is_finished_day": now >= end, "algorithm_version": "ENERGY_V1",
    }


def representative(weights):
    valid = [value for value in weights if not value.get("hidden") and not value.get("source_deleted")]
    if not valid:
        return None
    chosen = min(valid, key=lambda value: (
        -int(value.get("representative", False)),
        -datetime.fromisoformat(value["measured_at"].replace("Z", "+00:00")).timestamp(),
        -int(value.get("source") == "manual"), value.get("_record_id", ""),
    ))
    return chosen.get("corrected_weight_kg") or chosen["weight_kg"]

