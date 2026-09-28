#!/usr/bin/env python3
"""Generates Forge's built-in exercise library (App/Resources/exercises.json).

Run from the Forge directory:  python3 Tools/generate_exercises.py

Rules that keep user data safe:
  * An exercise's id is derived from its name the first time it's added and
    must NEVER change afterwards: workouts and routines refer to it forever.
    If you rename an exercise, pass the old id explicitly with id="...".
  * Never delete an entry; history may reference it. Mark it hidden instead
    if that's ever needed.
"""

import json
import re
import sys
import unicodedata
from pathlib import Path

CATALOG_VERSION = 1

LABELS = {
    "none": None,
    "barbell": "Barbell",
    "dumbbell": "Dumbbell",
    "kettlebell": "Kettlebell",
    "machine": "Machine",
    "cable": "Cable",
    "smith_machine": "Smith Machine",
    "ez_bar": "EZ Bar",
    "trap_bar": "Trap Bar",
    "band": "Band",
    "plate": "Plate",
    "medicine_ball": "Medicine Ball",
    "stability_ball": "Stability Ball",
    "suspension": "Suspension",
    "landmine": "Landmine",
    "sled": "Sled",
    "sandbag": "Sandbag",
    "rings": "Rings",
    "battle_rope": "Battle Rope",
    "jump_rope": "Jump Rope",
    "cardio_machine": "Machine",
    "foam_roller": "Foam Roller",
    "other": None,
}

MUSCLES = {
    "chest", "shoulders", "triceps", "biceps", "forearms", "lats", "upper_back", "traps",
    "lower_back", "abdominals", "obliques", "quadriceps", "hamstrings", "glutes", "adductors",
    "abductors", "calves", "neck", "full_body", "cardio", "other",
}
CATEGORIES = {"strength", "cardio", "plyometric", "olympic", "strongman", "calisthenics", "mobility", "sport"}
TRACKING = {
    "weight_reps", "reps", "weighted_bodyweight", "assisted_bodyweight", "duration",
    "weight_duration", "distance_duration", "weight_distance", "short_distance",
}

EXERCISES = []
IDS = set()
NAMES = set()


def slug(name):
    text = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    text = text.lower().replace("'", "").replace("’", "")
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text


def default_tracking(equipment):
    if equipment in ("none", "rings", "suspension"):
        return "reps"
    if equipment == "cardio_machine":
        return "distance_duration"
    return "weight_reps"


SUFFIX_EQUIPMENT = {label: key for key, label in LABELS.items() if label and key != "cardio_machine"}
SUFFIX_EQUIPMENT["Handles"] = "other"


def ex(name, primary, secondary=(), equipment=None, category="strength", tracking=None, aliases=(), id=None):
    # "Name (Barbell)" implies the equipment unless it's given explicitly.
    suffix = re.search(r"\(([^)]+)\)$", name)
    implied = SUFFIX_EQUIPMENT.get(suffix.group(1)) if suffix else None
    if equipment is None:
        equipment = implied or "none"
    elif implied and implied != equipment and equipment != "cardio_machine":
        raise SystemExit(f"{name}: equipment {equipment} contradicts its name")
    tracking = tracking or default_tracking(equipment)
    assert primary in MUSCLES, (name, primary)
    for muscle in secondary:
        assert muscle in MUSCLES, (name, muscle)
    assert equipment in LABELS, (name, equipment)
    assert category in CATEGORIES, (name, category)
    assert tracking in TRACKING, (name, tracking)
    identifier = id or slug(name)
    if identifier in IDS:
        raise SystemExit(f"duplicate id {identifier} ({name})")
    if name.lower() in NAMES:
        raise SystemExit(f"duplicate name {name}")
    IDS.add(identifier)
    NAMES.add(name.lower())
    entry = {
        "id": identifier,
        "name": name,
        "primary": primary,
        "equipment": equipment,
    }
    secondary = [m for m in secondary if m != primary]
    if secondary:
        entry["secondary"] = list(dict.fromkeys(secondary))
    if category != "strength":
        entry["category"] = category
    if tracking != "weight_reps":
        entry["tracking"] = tracking
    if aliases:
        entry["aliases"] = list(dict.fromkeys(aliases))
    EXERCISES.append(entry)


def V(base, equipments, primary, secondary=(), category="strength", tracking=None, aliases=(), bodyweight_name=None):
    """One exercise per equipment: 'Base (Equipment)'. Bodyweight ('none')
    keeps the bare name."""
    for equipment in equipments:
        label = LABELS[equipment]
        if equipment == "none":
            name = bodyweight_name or base
        else:
            name = f"{base} ({label})"
        t = tracking(equipment) if callable(tracking) else tracking
        ex(name, primary, secondary, equipment, category, t, aliases)


# ---------------------------------------------------------------- Chest
V("Bench Press", ["barbell", "dumbbell", "smith_machine", "cable", "band"], "chest", ["triceps", "shoulders"], aliases=["Flat Bench", "BB Bench", "Chest Press"])
V("Incline Bench Press", ["barbell", "dumbbell", "smith_machine"], "chest", ["shoulders", "triceps"], aliases=["Incline Press"])
V("Decline Bench Press", ["barbell", "dumbbell", "smith_machine"], "chest", ["triceps", "shoulders"], aliases=["Decline Press"])
V("Close-Grip Bench Press", ["barbell", "smith_machine", "dumbbell"], "triceps", ["chest", "shoulders"], aliases=["CGBP", "Narrow Grip Bench"])
V("Wide-Grip Bench Press", ["barbell"], "chest", ["shoulders", "triceps"])
V("Paused Bench Press", ["barbell"], "chest", ["triceps", "shoulders"], aliases=["Pause Bench", "Competition Bench"])
V("Spoto Press", ["barbell"], "chest", ["triceps", "shoulders"])
V("Larsen Press", ["barbell"], "chest", ["triceps", "shoulders"])
V("Board Press", ["barbell"], "triceps", ["chest", "shoulders"])
V("Pin Press", ["barbell"], "chest", ["triceps"], aliases=["Bench Pin Press"])
V("Floor Press", ["barbell", "dumbbell", "kettlebell"], "chest", ["triceps", "shoulders"])
V("Reverse-Grip Bench Press", ["barbell", "dumbbell"], "chest", ["triceps", "shoulders"], aliases=["Underhand Bench Press"])
V("Guillotine Press", ["barbell"], "chest", ["shoulders"])
V("Neutral-Grip Bench Press", ["dumbbell"], "chest", ["triceps"], aliases=["Hammer Grip Press"])
V("Squeeze Press", ["dumbbell"], "chest", ["triceps"], aliases=["Crush Press"])
V("Single-Arm Bench Press", ["dumbbell"], "chest", ["triceps", "abdominals"])
V("Alternating Bench Press", ["dumbbell"], "chest", ["triceps", "shoulders"])
V("Svend Press", ["plate"], "chest", ["shoulders"])
V("Chest Press", ["machine", "band"], "chest", ["triceps", "shoulders"], aliases=["Seated Chest Press"])
V("Incline Chest Press", ["machine"], "chest", ["shoulders", "triceps"])
V("Decline Chest Press", ["machine"], "chest", ["triceps"])
V("Iso-Lateral Chest Press", ["machine"], "chest", ["triceps", "shoulders"], aliases=["Hammer Strength Chest Press", "Plate-Loaded Chest Press"])
V("Iso-Lateral Incline Press", ["machine"], "chest", ["shoulders", "triceps"], aliases=["Hammer Strength Incline"])
V("Chest Fly", ["dumbbell", "cable", "machine", "band", "suspension"], "chest", ["shoulders"], aliases=["Chest Flye", "Pec Fly"])
V("Incline Chest Fly", ["dumbbell", "cable"], "chest", ["shoulders"], aliases=["Incline Flye"])
V("Decline Chest Fly", ["dumbbell", "cable"], "chest")
ex("Pec Deck (Machine)", "chest", ["shoulders"], "machine", aliases=["Butterfly", "Pec Fly Machine"])
ex("Cable Crossover", "chest", ["shoulders"], "cable", aliases=["Cable Cross", "Standing Cable Fly"])
ex("Low-to-High Cable Fly", "chest", ["shoulders"], "cable", aliases=["Low Cable Fly"])
ex("High-to-Low Cable Fly", "chest", [], "cable", aliases=["High Cable Fly"])
ex("Single-Arm Cable Fly", "chest", ["shoulders"], "cable")
ex("Single-Arm Cable Chest Press", "chest", ["triceps", "abdominals"], "cable")
V("Pullover", ["dumbbell", "barbell", "machine", "cable"], "chest", ["lats", "triceps"])
ex("Landmine Squeeze Press", "chest", ["shoulders", "triceps"], "landmine")
ex("Push-Up", "chest", ["triceps", "shoulders"], aliases=["Press-Up", "Pushup"])
ex("Knee Push-Up", "chest", ["triceps", "shoulders"], aliases=["Kneeling Push-Up", "Modified Push-Up"])
ex("Incline Push-Up", "chest", ["triceps", "shoulders"])
ex("Decline Push-Up", "chest", ["shoulders", "triceps"], aliases=["Feet-Elevated Push-Up"])
ex("Wide Push-Up", "chest", ["shoulders", "triceps"])
ex("Diamond Push-Up", "triceps", ["chest", "shoulders"], aliases=["Triangle Push-Up", "Close-Grip Push-Up"])
ex("Archer Push-Up", "chest", ["triceps", "shoulders"], category="calisthenics")
ex("Clap Push-Up", "chest", ["triceps", "shoulders"], category="plyometric")
ex("Plyometric Push-Up", "chest", ["triceps", "shoulders"], category="plyometric", aliases=["Explosive Push-Up"])
ex("Pike Push-Up", "shoulders", ["triceps", "chest"], category="calisthenics")
ex("Pseudo Planche Push-Up", "chest", ["shoulders", "triceps"], category="calisthenics")
ex("One-Arm Push-Up", "chest", ["triceps", "abdominals"], category="calisthenics")
ex("Deficit Push-Up", "chest", ["triceps", "shoulders"])
ex("Hand-Release Push-Up", "chest", ["triceps", "shoulders"], aliases=["HRPU"])
ex("Hindu Push-Up", "chest", ["shoulders", "triceps"], aliases=["Dive Bomber Push-Up"])
ex("Spiderman Push-Up", "chest", ["obliques", "triceps"])
ex("Weighted Push-Up", "chest", ["triceps", "shoulders"], "plate", tracking="weighted_bodyweight")
ex("Banded Push-Up", "chest", ["triceps", "shoulders"], "band", tracking="reps")
ex("Ring Push-Up", "chest", ["triceps", "shoulders"], "rings")
ex("Suspension Push-Up", "chest", ["triceps", "abdominals"], "suspension", aliases=["TRX Push-Up"])
ex("Stability Ball Push-Up", "chest", ["abdominals", "triceps"], "stability_ball", tracking="reps")
ex("Medicine Ball Push-Up", "chest", ["triceps", "shoulders"], "medicine_ball", tracking="reps")
ex("Chest Dip", "chest", ["triceps", "shoulders"], aliases=["Dip", "Dips"])
ex("Weighted Dip", "chest", ["triceps", "shoulders"], "plate", tracking="weighted_bodyweight", aliases=["Weighted Dips", "Dip Belt"])
ex("Assisted Dip (Machine)", "chest", ["triceps", "shoulders"], "machine", tracking="assisted_bodyweight")
ex("Assisted Dip (Band)", "chest", ["triceps", "shoulders"], "band", tracking="assisted_bodyweight")
ex("Ring Dip", "chest", ["triceps", "shoulders"], "rings", category="calisthenics")
ex("Straight Bar Dip", "chest", ["triceps", "shoulders"], category="calisthenics")

# ---------------------------------------------------------------- Back
ex("Pull-Up", "lats", ["biceps", "upper_back"], aliases=["Pullup"])
ex("Chin-Up", "lats", ["biceps", "upper_back"], aliases=["Chinup", "Underhand Pull-Up"])
ex("Neutral-Grip Pull-Up", "lats", ["biceps", "upper_back"], aliases=["Hammer Grip Pull-Up", "Parallel Grip Pull-Up"])
ex("Wide-Grip Pull-Up", "lats", ["upper_back", "biceps"])
ex("Weighted Pull-Up", "lats", ["biceps", "upper_back"], "plate", tracking="weighted_bodyweight")
ex("Weighted Chin-Up", "lats", ["biceps", "upper_back"], "plate", tracking="weighted_bodyweight")
ex("Assisted Pull-Up (Machine)", "lats", ["biceps", "upper_back"], "machine", tracking="assisted_bodyweight", aliases=["Gravitron"])
ex("Assisted Pull-Up (Band)", "lats", ["biceps", "upper_back"], "band", tracking="assisted_bodyweight")
ex("Assisted Chin-Up (Machine)", "lats", ["biceps"], "machine", tracking="assisted_bodyweight")
ex("Negative Pull-Up", "lats", ["biceps", "upper_back"], aliases=["Eccentric Pull-Up"])
ex("Jumping Pull-Up", "lats", ["biceps"], category="calisthenics")
ex("Kipping Pull-Up", "lats", ["biceps", "abdominals"], category="calisthenics")
ex("Butterfly Pull-Up", "lats", ["biceps", "abdominals"], category="calisthenics")
ex("Chest-to-Bar Pull-Up", "lats", ["biceps", "upper_back"], category="calisthenics", aliases=["C2B", "CTB"])
ex("L-Sit Pull-Up", "lats", ["abdominals", "biceps"], category="calisthenics")
ex("Archer Pull-Up", "lats", ["biceps", "upper_back"], category="calisthenics")
ex("Commando Pull-Up", "lats", ["biceps", "obliques"], category="calisthenics")
ex("Typewriter Pull-Up", "lats", ["biceps", "upper_back"], category="calisthenics")
ex("One-Arm Pull-Up", "lats", ["biceps", "forearms"], category="calisthenics")
ex("Scapular Pull-Up", "upper_back", ["lats"], aliases=["Scap Pull-Up"])
ex("Muscle-Up", "lats", ["chest", "triceps"], category="calisthenics", aliases=["Bar Muscle-Up", "BMU"])
ex("Ring Muscle-Up", "lats", ["chest", "triceps"], "rings", category="calisthenics", aliases=["RMU"])
ex("Rope Climb", "lats", ["biceps", "forearms"], "other", category="calisthenics", tracking="reps")
ex("Legless Rope Climb", "lats", ["biceps", "forearms", "abdominals"], "other", category="calisthenics", tracking="reps")
V("Lat Pulldown", ["cable", "machine", "band"], "lats", ["biceps", "upper_back"], aliases=["Pulldown", "Lat Pull"])
ex("Wide-Grip Lat Pulldown", "lats", ["upper_back", "biceps"], "cable")
ex("Close-Grip Lat Pulldown", "lats", ["biceps", "upper_back"], "cable", aliases=["V-Bar Pulldown"])
ex("Reverse-Grip Lat Pulldown", "lats", ["biceps"], "cable", aliases=["Underhand Pulldown", "Supinated Pulldown"])
ex("Neutral-Grip Lat Pulldown", "lats", ["biceps", "upper_back"], "cable")
ex("Single-Arm Lat Pulldown", "lats", ["biceps"], "cable")
ex("Behind-the-Neck Lat Pulldown", "lats", ["upper_back", "biceps"], "cable")
ex("Iso-Lateral Lat Pulldown (Machine)", "lats", ["biceps", "upper_back"], "machine", aliases=["Hammer Strength Pulldown"])
V("Straight-Arm Pulldown", ["cable", "band"], "lats", ["triceps"], aliases=["Straight-Arm Lat Pulldown", "Lat Prayer"])
V("Bent-Over Row", ["barbell", "dumbbell", "smith_machine"], "upper_back", ["lats", "biceps", "lower_back"], aliases=["Barbell Row", "BB Row", "Bent Over Row"])
ex("Pendlay Row (Barbell)", "upper_back", ["lats", "biceps", "lower_back"])
ex("Yates Row (Barbell)", "lats", ["biceps", "upper_back"], aliases=["Underhand Row", "Reverse-Grip Row"])
V("Seal Row", ["barbell", "dumbbell"], "upper_back", ["lats", "biceps"])
V("Chest-Supported Row", ["dumbbell", "machine"], "upper_back", ["lats", "biceps"], aliases=["Incline Row", "Chest Supported Row"])
V("T-Bar Row", ["landmine", "machine"], "upper_back", ["lats", "biceps"], aliases=["T Bar Row"])
V("Single-Arm Row", ["dumbbell", "kettlebell", "cable", "band"], "lats", ["upper_back", "biceps"], aliases=["One-Arm Row", "Dumbbell Row"])
ex("Kroc Row (Dumbbell)", "lats", ["upper_back", "forearms", "biceps"])
ex("Meadows Row (Landmine)", "lats", ["upper_back", "biceps"])
ex("Helms Row (Dumbbell)", "upper_back", ["lats", "biceps"])
ex("Seated Cable Row", "upper_back", ["lats", "biceps"], "cable", aliases=["Cable Row", "Low Row"])
ex("Wide-Grip Seated Cable Row", "upper_back", ["lats", "shoulders"], "cable")
ex("Single-Arm Seated Cable Row", "lats", ["upper_back", "biceps"], "cable")
V("Seated Row", ["machine", "band"], "upper_back", ["lats", "biceps"])
ex("High Row (Machine)", "upper_back", ["lats", "biceps"])
ex("Low Row (Machine)", "lats", ["upper_back", "biceps"])
ex("Iso-Lateral Row (Machine)", "upper_back", ["lats", "biceps"], aliases=["Hammer Strength Row"])
ex("Inverted Row", "upper_back", ["lats", "biceps"], aliases=["Australian Pull-Up", "Bodyweight Row"])
ex("Ring Row", "upper_back", ["lats", "biceps"], "rings")
ex("Suspension Row", "upper_back", ["lats", "biceps"], "suspension", aliases=["TRX Row"])
ex("Renegade Row (Dumbbell)", "upper_back", ["abdominals", "lats"])
ex("Gorilla Row (Kettlebell)", "upper_back", ["lats", "biceps"])
V("Face Pull", ["cable", "band"], "shoulders", ["upper_back", "traps"], aliases=["Rope Face Pull"])
V("Rear Delt Fly", ["dumbbell", "cable", "machine", "band"], "shoulders", ["upper_back"], aliases=["Reverse Fly", "Rear Delt Flye", "Bent-Over Reverse Fly"])
ex("Band Pull-Apart", "upper_back", ["shoulders"], "band", tracking="reps", aliases=["Pull Apart"])
V("Shrug", ["barbell", "dumbbell", "smith_machine", "trap_bar", "cable", "machine", "kettlebell"], "traps", ["forearms"], aliases=["Shrugs"])
ex("Behind-the-Back Shrug (Barbell)", "traps", ["forearms"])
ex("Overhead Shrug (Barbell)", "traps", ["shoulders"])
V("Rack Pull", ["barbell", "trap_bar"], "lower_back", ["traps", "glutes", "hamstrings", "forearms"], aliases=["Block Pull"])
ex("Back Extension", "lower_back", ["glutes", "hamstrings"], aliases=["Hyperextension", "45° Back Extension"])
ex("Weighted Back Extension", "lower_back", ["glutes", "hamstrings"], "plate", tracking="weighted_bodyweight", aliases=["Weighted Hyperextension"])
ex("Back Extension (Machine)", "lower_back", ["glutes"], "machine")
ex("Reverse Hyperextension (Machine)", "glutes", ["hamstrings", "lower_back"], "machine", aliases=["Reverse Hyper"])
ex("Superman", "lower_back", ["glutes"])
ex("Superman Hold", "lower_back", ["glutes"], tracking="duration", aliases=["Arch Hold"])
ex("Bird Dog", "lower_back", ["abdominals", "glutes"])
V("Good Morning", ["barbell", "smith_machine", "band", "dumbbell"], "hamstrings", ["lower_back", "glutes"])
ex("Seated Good Morning (Barbell)", "lower_back", ["hamstrings"])
V("Jefferson Curl", ["barbell", "dumbbell", "kettlebell"], "lower_back", ["hamstrings"], category="mobility")

# ---------------------------------------------------------------- Shoulders
V("Overhead Press", ["barbell", "dumbbell", "smith_machine", "kettlebell", "band"], "shoulders", ["triceps", "upper_back"], aliases=["OHP", "Military Press", "Strict Press", "Standing Press"])
V("Seated Overhead Press", ["barbell", "dumbbell"], "shoulders", ["triceps"], aliases=["Seated Shoulder Press"])
V("Shoulder Press", ["machine", "cable"], "shoulders", ["triceps"])
ex("Iso-Lateral Shoulder Press (Machine)", "shoulders", ["triceps"], "machine", aliases=["Hammer Strength Shoulder Press"])
V("Single-Arm Overhead Press", ["dumbbell", "kettlebell"], "shoulders", ["triceps", "abdominals"])
ex("Push Press (Barbell)", "shoulders", ["triceps", "quadriceps"], category="olympic")
V("Push Press", ["dumbbell", "kettlebell"], "shoulders", ["triceps", "quadriceps"])
ex("Behind-the-Neck Press (Barbell)", "shoulders", ["triceps", "upper_back"])
V("Z Press", ["barbell", "dumbbell"], "shoulders", ["triceps", "abdominals"])
ex("Bradford Press (Barbell)", "shoulders", ["triceps"])
V("Arnold Press", ["dumbbell", "kettlebell"], "shoulders", ["triceps"])
ex("Bottoms-Up Press (Kettlebell)", "shoulders", ["forearms", "triceps"])
ex("Landmine Press", "shoulders", ["chest", "triceps"], "landmine")
ex("Half-Kneeling Landmine Press", "shoulders", ["abdominals", "chest", "triceps"], "landmine")
ex("Viking Press (Landmine)", "shoulders", ["triceps"])
V("Lateral Raise", ["dumbbell", "cable", "machine", "band", "kettlebell"], "shoulders", [], aliases=["Side Raise", "Side Lateral Raise", "Lat Raise"])
ex("Seated Lateral Raise (Dumbbell)", "shoulders")
V("Leaning Lateral Raise", ["dumbbell", "cable"], "shoulders")
ex("Lu Raise (Dumbbell)", "shoulders", ["traps"])
V("Y-Raise", ["dumbbell", "cable"], "shoulders", ["upper_back", "traps"])
V("Front Raise", ["dumbbell", "barbell", "cable", "plate", "band"], "shoulders", ["chest"])
V("Upright Row", ["barbell", "dumbbell", "cable", "smith_machine", "ez_bar", "kettlebell"], "shoulders", ["traps"])
ex("Cuban Press (Dumbbell)", "shoulders", ["upper_back"])
V("External Rotation", ["cable", "dumbbell", "band"], "shoulders", [], aliases=["Rotator Cuff External Rotation"])
V("Internal Rotation", ["cable", "band"], "shoulders", [], aliases=["Rotator Cuff Internal Rotation"])
ex("Scaption (Dumbbell)", "shoulders", ["traps"])
ex("Bus Driver (Plate)", "shoulders", ["forearms"])
ex("Handstand Push-Up", "shoulders", ["triceps"], category="calisthenics", aliases=["HSPU", "Strict Handstand Push-Up"])
ex("Kipping Handstand Push-Up", "shoulders", ["triceps", "abdominals"], category="calisthenics")
ex("Wall Walk", "shoulders", ["abdominals", "chest"], category="calisthenics")
ex("Handstand Hold", "shoulders", ["abdominals", "triceps"], tracking="duration", category="calisthenics", aliases=["Wall Handstand"])
ex("Handstand Walk", "shoulders", ["abdominals"], tracking="short_distance", category="calisthenics")
ex("Halo (Kettlebell)", "shoulders", ["upper_back"], aliases=["Kettlebell Halo"])
ex("Plate Halo", "shoulders", ["upper_back"], "plate")

# ---------------------------------------------------------------- Biceps
V("Bicep Curl", ["barbell", "dumbbell", "ez_bar", "cable", "machine", "band", "kettlebell"], "biceps", ["forearms"], aliases=["Biceps Curl", "Curl"])
ex("Alternating Bicep Curl (Dumbbell)", "biceps", ["forearms"])
ex("Seated Bicep Curl (Dumbbell)", "biceps", ["forearms"])
V("Hammer Curl", ["dumbbell", "cable", "band"], "biceps", ["forearms"], aliases=["Rope Hammer Curl"])
ex("Cross-Body Hammer Curl (Dumbbell)", "biceps", ["forearms"], aliases=["Pinwheel Curl"])
V("Preacher Curl", ["barbell", "ez_bar", "dumbbell", "machine", "cable"], "biceps")
ex("Incline Curl (Dumbbell)", "biceps", aliases=["Incline Dumbbell Curl"])
ex("Concentration Curl (Dumbbell)", "biceps")
V("Spider Curl", ["dumbbell", "ez_bar", "barbell"], "biceps")
ex("Drag Curl (Barbell)", "biceps")
V("Reverse Curl", ["barbell", "ez_bar", "dumbbell", "cable"], "forearms", ["biceps"])
ex("Zottman Curl (Dumbbell)", "biceps", ["forearms"])
ex("Bayesian Curl (Cable)", "biceps", aliases=["Behind-the-Body Cable Curl"])
ex("High Cable Curl", "biceps", [], "cable", aliases=["Overhead Cable Curl", "Double Biceps Cable Curl"])
ex("21s (Barbell)", "biceps", ["forearms"], aliases=["21s Bicep Curl"])
ex("Waiter Curl (Dumbbell)", "biceps")
ex("Suspension Bicep Curl", "biceps", [], "suspension", aliases=["TRX Bicep Curl"])

# ---------------------------------------------------------------- Triceps
V("Triceps Pushdown", ["cable", "band"], "triceps", aliases=["Tricep Pushdown", "Pressdown", "Straight Bar Pushdown"])
ex("Triceps Rope Pushdown", "triceps", [], "cable", aliases=["Rope Pushdown"])
ex("Reverse-Grip Triceps Pushdown", "triceps", [], "cable")
ex("Single-Arm Triceps Pushdown", "triceps", [], "cable")
V("Overhead Triceps Extension", ["dumbbell", "cable", "band", "ez_bar", "barbell"], "triceps", aliases=["French Press", "Overhead Extension"])
ex("Single-Arm Overhead Triceps Extension (Dumbbell)", "triceps")
V("Skull Crusher", ["barbell", "ez_bar", "dumbbell"], "triceps", aliases=["Lying Triceps Extension", "Nose Breaker"])
ex("JM Press (Barbell)", "triceps", ["chest"])
ex("Tate Press (Dumbbell)", "triceps", ["chest"])
V("Triceps Kickback", ["dumbbell", "cable"], "triceps", aliases=["Tricep Kickback"])
ex("Triceps Dip", "triceps", ["chest", "shoulders"], aliases=["Parallel Bar Dip"])
ex("Bench Dip", "triceps", ["chest", "shoulders"])
ex("Seated Dip (Machine)", "triceps", ["chest", "shoulders"])
ex("Triceps Extension (Machine)", "triceps")
ex("California Press (Barbell)", "triceps", ["chest"])
ex("Rolling Triceps Extension (Dumbbell)", "triceps")
ex("Cross-Body Triceps Extension (Cable)", "triceps")
ex("Bodyweight Triceps Extension", "triceps", ["abdominals"], aliases=["Bar Triceps Extension"])
ex("Suspension Triceps Extension", "triceps", [], "suspension", aliases=["TRX Triceps Extension"])

# ---------------------------------------------------------------- Forearms & grip
V("Wrist Curl", ["barbell", "dumbbell", "cable"], "forearms")
V("Reverse Wrist Curl", ["barbell", "dumbbell"], "forearms")
ex("Behind-the-Back Wrist Curl (Barbell)", "forearms")
ex("Wrist Roller", "forearms", [], "other", tracking="reps")
ex("Hand Gripper", "forearms", [], "other", tracking="reps", aliases=["Grip Trainer", "Grippers"])
ex("Plate Pinch", "forearms", [], "plate", tracking="weight_duration")
ex("Dead Hang", "forearms", ["lats", "shoulders"], tracking="duration", aliases=["Bar Hang", "Passive Hang"])
ex("Active Hang", "lats", ["forearms", "shoulders"], tracking="duration", category="calisthenics")
V("Farmer's Hold", ["dumbbell", "kettlebell", "trap_bar"], "forearms", ["traps"], tracking="weight_duration", aliases=["Farmers Hold"])

# ---------------------------------------------------------------- Quads & squats
V("Squat", ["barbell", "dumbbell", "smith_machine", "band"], "quadriceps", ["glutes", "hamstrings", "lower_back"], aliases=["Back Squat", "High-Bar Squat"])
V("Front Squat", ["barbell", "kettlebell", "dumbbell"], "quadriceps", ["glutes", "abdominals"])
ex("Low-Bar Squat (Barbell)", "quadriceps", ["glutes", "hamstrings", "lower_back"])
ex("Pause Squat (Barbell)", "quadriceps", ["glutes"], aliases=["Paused Squat"])
ex("Box Squat (Barbell)", "quadriceps", ["glutes", "hamstrings"])
ex("Pin Squat (Barbell)", "quadriceps", ["glutes"], aliases=["Anderson Squat"])
ex("Safety Bar Squat", "quadriceps", ["glutes", "upper_back"], "barbell", aliases=["SSB Squat", "Safety Squat Bar"])
ex("Zercher Squat (Barbell)", "quadriceps", ["glutes", "abdominals", "biceps"])
ex("Overhead Squat (Barbell)", "quadriceps", ["shoulders", "abdominals", "glutes"], category="olympic", aliases=["OHS"])
V("Goblet Squat", ["dumbbell", "kettlebell"], "quadriceps", ["glutes", "abdominals"])
ex("Heel-Elevated Goblet Squat (Dumbbell)", "quadriceps", ["glutes"], aliases=["Cyclist Squat"])
V("Hack Squat", ["machine", "barbell"], "quadriceps", ["glutes"])
ex("Pendulum Squat (Machine)", "quadriceps", ["glutes"])
ex("Belt Squat (Machine)", "quadriceps", ["glutes"])
ex("V-Squat (Machine)", "quadriceps", ["glutes"])
ex("Landmine Squat", "quadriceps", ["glutes"], "landmine")
ex("Sissy Squat", "quadriceps")
ex("Bodyweight Squat", "quadriceps", ["glutes"], aliases=["Air Squat"])
ex("Jump Squat", "quadriceps", ["glutes", "calves"], category="plyometric", aliases=["Squat Jump"])
ex("Jump Squat (Dumbbell)", "quadriceps", ["glutes", "calves"], "dumbbell", category="plyometric")
ex("Pistol Squat", "quadriceps", ["glutes"], category="calisthenics", aliases=["Single-Leg Squat"])
ex("Shrimp Squat", "quadriceps", ["glutes"], category="calisthenics")
V("Cossack Squat", ["none", "kettlebell", "dumbbell"], "adductors", ["quadriceps", "glutes"])
ex("Wall Sit", "quadriceps", ["glutes"], tracking="duration")
ex("Weighted Wall Sit", "quadriceps", ["glutes"], "plate", tracking="weight_duration")
V("Split Squat", ["none", "dumbbell", "barbell", "smith_machine", "kettlebell"], "quadriceps", ["glutes"])
V("Bulgarian Split Squat", ["none", "dumbbell", "barbell", "smith_machine", "kettlebell"], "quadriceps", ["glutes", "hamstrings"], aliases=["BSS", "Rear-Foot-Elevated Split Squat", "RFESS"])
V("Lunge", ["none", "dumbbell", "barbell", "kettlebell", "smith_machine"], "quadriceps", ["glutes", "hamstrings"], aliases=["Forward Lunge"])
V("Reverse Lunge", ["none", "dumbbell", "barbell", "kettlebell"], "quadriceps", ["glutes", "hamstrings"])
V("Walking Lunge", ["none", "dumbbell", "barbell", "kettlebell"], "quadriceps", ["glutes", "hamstrings"])
V("Lateral Lunge", ["none", "dumbbell", "kettlebell"], "quadriceps", ["adductors", "glutes"], aliases=["Side Lunge"])
V("Curtsy Lunge", ["none", "dumbbell"], "glutes", ["quadriceps", "abductors"])
ex("Overhead Walking Lunge (Plate)", "quadriceps", ["shoulders", "glutes", "abdominals"])
ex("Front Rack Lunge (Barbell)", "quadriceps", ["glutes", "abdominals"])
ex("Jumping Lunge", "quadriceps", ["glutes", "calves"], category="plyometric", aliases=["Split Squat Jump", "Lunge Jump"])
V("Step-Up", ["none", "dumbbell", "barbell", "kettlebell"], "quadriceps", ["glutes"], aliases=["Box Step-Up"])
ex("Lateral Step-Up", "quadriceps", ["glutes", "abductors"])
ex("Leg Press (Machine)", "quadriceps", ["glutes", "hamstrings"], aliases=["45° Leg Press", "Sled Leg Press"])
ex("Single-Leg Leg Press (Machine)", "quadriceps", ["glutes"])
ex("Horizontal Leg Press (Machine)", "quadriceps", ["glutes"], aliases=["Seated Leg Press"])
ex("Leg Extension (Machine)", "quadriceps", aliases=["Quad Extension"])
ex("Single-Leg Leg Extension (Machine)", "quadriceps")
ex("Leg Extension (Band)", "quadriceps", [], "band")
ex("Reverse Nordic", "quadriceps")
ex("Spanish Squat (Band)", "quadriceps", [], "band", tracking="reps")
ex("Sled Push", "quadriceps", ["glutes", "calves"], "sled", tracking="weight_distance", aliases=["Prowler Push"])
ex("Backward Sled Drag", "quadriceps", ["glutes"], "sled", tracking="weight_distance", aliases=["Reverse Sled Drag"])
V("Thruster", ["barbell", "dumbbell", "kettlebell"], "full_body", ["quadriceps", "shoulders", "glutes"])
ex("Wall Ball", "full_body", ["quadriceps", "shoulders"], "medicine_ball", aliases=["Wall Ball Shot", "Wall Balls"])

# ---------------------------------------------------------------- Hamstrings, glutes & hinge
V("Deadlift", ["barbell", "dumbbell", "kettlebell", "trap_bar", "smith_machine", "band"], "lower_back", ["glutes", "hamstrings", "traps", "forearms"], aliases=["Conventional Deadlift", "DL"])
V("Sumo Deadlift", ["barbell", "dumbbell", "kettlebell"], "glutes", ["hamstrings", "adductors", "quadriceps", "lower_back"])
V("Romanian Deadlift", ["barbell", "dumbbell", "kettlebell", "smith_machine", "trap_bar"], "hamstrings", ["glutes", "lower_back"], aliases=["RDL"])
V("Stiff-Leg Deadlift", ["barbell", "dumbbell"], "hamstrings", ["glutes", "lower_back"], aliases=["SLDL", "Straight-Leg Deadlift"])
V("Single-Leg Romanian Deadlift", ["none", "dumbbell", "kettlebell", "barbell"], "hamstrings", ["glutes", "lower_back"], aliases=["Single-Leg RDL", "SLRDL"])
ex("Deficit Deadlift (Barbell)", "lower_back", ["glutes", "hamstrings", "quadriceps"])
ex("Paused Deadlift (Barbell)", "lower_back", ["glutes", "hamstrings"])
ex("Snatch-Grip Deadlift (Barbell)", "lower_back", ["upper_back", "hamstrings", "traps"])
V("Suitcase Deadlift", ["dumbbell", "kettlebell"], "obliques", ["glutes", "forearms", "lower_back"])
ex("Kettlebell Swing", "glutes", ["hamstrings", "lower_back", "shoulders"], "kettlebell", aliases=["KB Swing", "Russian Kettlebell Swing"])
ex("American Kettlebell Swing", "glutes", ["hamstrings", "shoulders", "lower_back"], "kettlebell", aliases=["Overhead Swing"])
ex("Single-Arm Kettlebell Swing", "glutes", ["hamstrings", "obliques"], "kettlebell")
ex("Cable Pull-Through", "glutes", ["hamstrings"], "cable")
V("Hip Thrust", ["barbell", "dumbbell", "smith_machine", "machine", "band", "none"], "glutes", ["hamstrings"])
V("Single-Leg Hip Thrust", ["none", "dumbbell"], "glutes", ["hamstrings"])
ex("B-Stance Hip Thrust (Barbell)", "glutes", ["hamstrings"])
V("Glute Bridge", ["none", "barbell", "dumbbell", "band"], "glutes", ["hamstrings"])
ex("Single-Leg Glute Bridge", "glutes", ["hamstrings"])
ex("Frog Pump", "glutes", ["adductors"])
V("Glute Kickback", ["cable", "machine", "band"], "glutes", ["hamstrings"])
ex("Donkey Kick", "glutes", ["hamstrings"], aliases=["Quadruped Kickback"])
ex("Fire Hydrant", "abductors", ["glutes"])
V("Hip Abduction", ["machine", "cable", "band"], "abductors", ["glutes"], aliases=["Abductor Machine", "Outer Thigh"])
V("Hip Adduction", ["machine", "cable"], "adductors", aliases=["Adductor Machine", "Inner Thigh"])
ex("Lateral Band Walk", "abductors", ["glutes"], "band", tracking="reps", aliases=["Monster Walk", "Band Walk"])
V("Clamshell", ["none", "band"], "abductors", ["glutes"], tracking="reps")
ex("Side-Lying Leg Raise", "abductors", ["glutes"])
ex("Copenhagen Plank", "adductors", ["obliques"], tracking="duration", aliases=["Copenhagen Side Plank"])
ex("Lying Leg Curl (Machine)", "hamstrings", ["calves"], aliases=["Prone Leg Curl"])
ex("Seated Leg Curl (Machine)", "hamstrings")
ex("Standing Leg Curl (Machine)", "hamstrings")
V("Leg Curl", ["cable", "band", "dumbbell"], "hamstrings")
ex("Stability Ball Leg Curl", "hamstrings", ["glutes"], "stability_ball", tracking="reps", aliases=["Swiss Ball Hamstring Curl"])
ex("Slider Leg Curl", "hamstrings", ["glutes"], "other", tracking="reps")
ex("Nordic Hamstring Curl", "hamstrings", aliases=["Nordic Curl", "Nordics"])
ex("Glute-Ham Raise", "hamstrings", ["glutes", "calves"], "machine", tracking="reps", aliases=["GHR"])
ex("Sled Drag", "hamstrings", ["glutes", "calves"], "sled", tracking="weight_distance")

# ---------------------------------------------------------------- Calves
V("Standing Calf Raise", ["machine", "smith_machine", "dumbbell", "barbell", "none"], "calves", aliases=["Calf Raise"])
V("Seated Calf Raise", ["machine", "dumbbell", "barbell"], "calves")
V("Single-Leg Calf Raise", ["none", "dumbbell"], "calves")
ex("Donkey Calf Raise (Machine)", "calves")
ex("Leg Press Calf Raise (Machine)", "calves", aliases=["Calf Press"])
ex("Tibialis Raise", "calves", aliases=["Tib Raise", "Tibialis Anterior Raise"])

# ---------------------------------------------------------------- Core
ex("Crunch", "abdominals")
ex("Weighted Crunch", "abdominals", [], "plate")
ex("Cable Crunch", "abdominals", [], "cable", aliases=["Kneeling Cable Crunch"])
ex("Ab Crunch (Machine)", "abdominals", [], "machine", aliases=["Crunch Machine"])
ex("Decline Crunch", "abdominals")
ex("Bicycle Crunch", "abdominals", ["obliques"])
ex("Reverse Crunch", "abdominals")
ex("Stability Ball Crunch", "abdominals", [], "stability_ball", tracking="reps", aliases=["Swiss Ball Crunch"])
ex("Oblique Crunch", "obliques", ["abdominals"])
ex("V-Up", "abdominals")
ex("Jackknife Sit-Up", "abdominals")
ex("Sit-Up", "abdominals")
ex("Weighted Sit-Up", "abdominals", [], "plate")
ex("Decline Sit-Up", "abdominals")
ex("GHD Sit-Up", "abdominals", ["quadriceps"], "machine", tracking="reps", aliases=["Glute-Ham Developer Sit-Up"])
ex("Butterfly Sit-Up", "abdominals", aliases=["AbMat Sit-Up"])
ex("Toes-to-Bar", "abdominals", ["lats", "forearms"], category="calisthenics", aliases=["T2B", "TTB"])
ex("Knees-to-Elbows", "abdominals", ["lats"], aliases=["K2E"])
ex("Hanging Leg Raise", "abdominals", ["forearms"])
ex("Hanging Knee Raise", "abdominals", ["forearms"])
ex("Captain's Chair Leg Raise", "abdominals", [], "machine", tracking="reps", aliases=["Vertical Knee Raise", "Roman Chair Leg Raise"])
ex("Lying Leg Raise", "abdominals")
ex("Flutter Kick", "abdominals", aliases=["Flutter Kicks"])
ex("Scissor Kick", "abdominals", aliases=["Scissor Kicks"])
ex("Dead Bug", "abdominals")
ex("Plank", "abdominals", ["shoulders"], tracking="duration", aliases=["Front Plank", "Forearm Plank"])
ex("Side Plank", "obliques", ["abdominals"], tracking="duration")
ex("Weighted Plank", "abdominals", ["shoulders"], "plate", tracking="weight_duration")
ex("RKC Plank", "abdominals", ["glutes"], tracking="duration")
ex("Plank Shoulder Tap", "abdominals", ["shoulders"], aliases=["Shoulder Taps"])
ex("Plank Jack", "abdominals", ["shoulders"])
ex("Hollow Body Hold", "abdominals", tracking="duration", aliases=["Hollow Hold"])
ex("Hollow Rock", "abdominals")
ex("L-Sit", "abdominals", ["triceps", "quadriceps"], tracking="duration", category="calisthenics")
ex("V-Sit Hold", "abdominals", tracking="duration", category="calisthenics")
ex("Dragon Flag", "abdominals", ["lower_back"], category="calisthenics")
ex("Ab Wheel Rollout", "abdominals", ["lats", "shoulders"], "other", tracking="reps", aliases=["Ab Roller", "Ab Wheel"])
ex("Barbell Rollout", "abdominals", ["lats"], "barbell", tracking="reps")
ex("Stability Ball Rollout", "abdominals", [], "stability_ball", tracking="reps")
ex("Stir the Pot", "abdominals", ["obliques"], "stability_ball", tracking="reps")
ex("Mountain Climber", "abdominals", ["shoulders", "quadriceps"], aliases=["Mountain Climbers"])
V("Russian Twist", ["none", "plate", "medicine_ball", "dumbbell"], "obliques", ["abdominals"])
V("Woodchop", ["cable", "band", "dumbbell", "medicine_ball"], "obliques", ["abdominals", "shoulders"], aliases=["Wood Chopper", "Cable Woodchop"])
V("Pallof Press", ["cable", "band"], "obliques", ["abdominals"], aliases=["Anti-Rotation Press"])
ex("Landmine Rotation", "obliques", ["shoulders", "abdominals"], "landmine", aliases=["Landmine 180", "Landmine Twist"])
ex("Windshield Wiper", "obliques", ["abdominals"], aliases=["Hanging Windshield Wiper"])
ex("Heel Touch", "obliques", aliases=["Heel Taps"])
ex("Toe Touch", "abdominals", aliases=["Toe Touches", "Crunch Toe Touch"])
V("Side Bend", ["dumbbell", "cable", "kettlebell", "plate"], "obliques")
ex("Rotary Torso (Machine)", "obliques", [], "machine", aliases=["Torso Rotation"])
ex("Bear Crawl", "full_body", ["shoulders", "abdominals"], tracking="short_distance")
V("Suitcase Carry", ["dumbbell", "kettlebell"], "obliques", ["forearms", "traps"], tracking="weight_distance")
V("Farmer's Walk", ["dumbbell", "kettlebell", "trap_bar"], "forearms", ["traps", "abdominals", "full_body"], tracking="weight_distance", aliases=["Farmers Walk", "Farmer's Carry", "Farmers Carry"])
ex("Farmer's Walk (Handles)", "forearms", ["traps", "abdominals", "full_body"], "other", category="strongman", tracking="weight_distance", aliases=["Farmers Walk"])
V("Overhead Carry", ["dumbbell", "kettlebell", "plate"], "shoulders", ["abdominals", "traps"], tracking="weight_distance", aliases=["Overhead Walk"])
ex("Front Rack Carry (Kettlebell)", "abdominals", ["upper_back", "shoulders"], tracking="weight_distance")
ex("Waiter Walk (Kettlebell)", "shoulders", ["abdominals"], tracking="weight_distance")
ex("Zercher Carry (Barbell)", "full_body", ["biceps", "abdominals"], tracking="weight_distance")

# ---------------------------------------------------------------- Neck
ex("Neck Curl (Plate)", "neck", aliases=["Neck Flexion"])
ex("Neck Extension (Plate)", "neck", aliases=["Neck Extension"])
ex("Lateral Neck Flexion (Plate)", "neck", aliases=["Neck Side Flexion"])
ex("Neck Harness Extension", "neck", ["traps"], "other")
ex("4-Way Neck (Machine)", "neck", ["traps"], "machine")

# ---------------------------------------------------------------- Olympic lifting
def oly(name, primary="full_body", secondary=("quadriceps", "glutes", "traps", "shoulders"), equipment=None, aliases=()):
    ex(name, primary, list(secondary), equipment, category="olympic", aliases=aliases)

oly("Clean (Barbell)", aliases=["Squat Clean"])
oly("Power Clean (Barbell)", aliases=["PC"])
oly("Hang Clean (Barbell)", aliases=["Hang Squat Clean"])
oly("Hang Power Clean (Barbell)", aliases=["HPC"])
oly("Clean Pull (Barbell)", "traps", ["hamstrings", "glutes", "lower_back"])
oly("Muscle Clean (Barbell)", "traps", ["shoulders", "upper_back"])
oly("Clean and Jerk (Barbell)", aliases=["C&J", "Clean & Jerk"])
oly("Split Jerk (Barbell)", "shoulders", ["quadriceps", "triceps", "glutes"])
oly("Push Jerk (Barbell)", "shoulders", ["quadriceps", "triceps"])
oly("Power Jerk (Barbell)", "shoulders", ["quadriceps", "triceps"])
oly("Snatch (Barbell)", aliases=["Squat Snatch", "Full Snatch"])
oly("Power Snatch (Barbell)")
oly("Hang Snatch (Barbell)")
oly("Hang Power Snatch (Barbell)", aliases=["HPS"])
oly("Snatch Pull (Barbell)", "traps", ["hamstrings", "glutes", "lower_back"])
oly("Snatch Balance (Barbell)", "quadriceps", ["shoulders", "abdominals"])
oly("Muscle Snatch (Barbell)", "shoulders", ["traps", "upper_back"])
oly("Sots Press (Barbell)", "shoulders", ["quadriceps", "abdominals"])
oly("High Pull (Barbell)", "traps", ["shoulders", "hamstrings"])
oly("Sumo Deadlift High Pull (Barbell)", "traps", ["glutes", "shoulders", "hamstrings"], aliases=["SDHP"])
oly("Sumo Deadlift High Pull (Kettlebell)", "traps", ["glutes", "shoulders"], "kettlebell", aliases=["KB SDHP"])
oly("Snatch (Dumbbell)", aliases=["DB Snatch", "Dumbbell Snatch"], equipment="dumbbell")
oly("Clean (Dumbbell)", equipment="dumbbell", aliases=["DB Clean"])
oly("Hang Clean (Dumbbell)", equipment="dumbbell")
oly("Clean and Jerk (Dumbbell)", equipment="dumbbell", aliases=["DB Clean and Jerk"])
oly("Clean and Press (Dumbbell)", equipment="dumbbell")
oly("Snatch (Kettlebell)", equipment="kettlebell", aliases=["KB Snatch"])
oly("Clean (Kettlebell)", equipment="kettlebell", aliases=["KB Clean"])
oly("Clean and Press (Kettlebell)", equipment="kettlebell")
oly("Clean and Jerk (Kettlebell)", equipment="kettlebell")
ex("Turkish Get-Up (Kettlebell)", "full_body", ["shoulders", "abdominals", "glutes"], "kettlebell", aliases=["TGU", "Get-Up"])
ex("Turkish Get-Up (Dumbbell)", "full_body", ["shoulders", "abdominals", "glutes"], "dumbbell", aliases=["TGU"])
ex("Windmill (Kettlebell)", "obliques", ["shoulders", "hamstrings"], "kettlebell", aliases=["Kettlebell Windmill"])
ex("Devil Press (Dumbbell)", "full_body", ["chest", "shoulders", "glutes"], "dumbbell", aliases=["Devil's Press"])
ex("Man Maker (Dumbbell)", "full_body", ["chest", "shoulders", "upper_back"], "dumbbell")
V("Cluster", ["barbell", "dumbbell"], "full_body", ["quadriceps", "shoulders"], aliases=["Squat Clean Thruster"])
V("Ground to Overhead", ["barbell", "dumbbell", "plate"], "full_body", ["shoulders", "quadriceps"], aliases=["GTOH"])
ex("Shoulder to Overhead (Barbell)", "shoulders", ["triceps", "quadriceps"], aliases=["STOH"])

# ---------------------------------------------------------------- Conditioning & plyometrics
def ply(name, primary, secondary=(), equipment=None, tracking=None, aliases=()):
    ex(name, primary, list(secondary), equipment, category="plyometric", tracking=tracking, aliases=aliases)

ply("Burpee", "full_body", ["chest", "quadriceps", "shoulders"], aliases=["Burpees"])
ply("Burpee Box Jump Over", "full_body", ["quadriceps", "chest"], aliases=["BBJO"])
ply("Bar-Facing Burpee", "full_body", ["chest", "quadriceps"], aliases=["Burpee Over Bar"])
ply("Burpee Pull-Up", "full_body", ["lats", "chest"])
ply("Sprawl", "full_body", ["chest", "quadriceps"])
ply("Box Jump", "quadriceps", ["glutes", "calves"], "other", tracking="reps")
ply("Box Jump Over", "quadriceps", ["glutes", "calves"], "other", tracking="reps")
ply("Single-Leg Box Jump", "quadriceps", ["glutes", "calves"], "other", tracking="reps")
ply("Lateral Box Jump", "quadriceps", ["glutes", "abductors"], "other", tracking="reps")
ply("Seated Box Jump", "quadriceps", ["glutes"], "other", tracking="reps")
ply("Depth Jump", "quadriceps", ["glutes", "calves"], "other", tracking="reps")
ply("Broad Jump", "quadriceps", ["glutes", "hamstrings"], aliases=["Standing Long Jump"])
ply("Tuck Jump", "quadriceps", ["abdominals", "calves"])
ply("Skater Jump", "glutes", ["quadriceps", "abductors"], aliases=["Skaters", "Lateral Bound"])
ply("Single-Leg Hop", "calves", ["quadriceps"])
ply("Pogo Jump", "calves", aliases=["Pogo Hops"])
ply("Hurdle Hop", "quadriceps", ["calves", "glutes"])
ply("Star Jump", "full_body", ["shoulders", "quadriceps"])
ply("Frog Jump", "quadriceps", ["glutes"])
ply("Kneeling Jump", "glutes", ["quadriceps"])
ply("Bounding", "quadriceps", ["glutes", "hamstrings"], tracking="short_distance")
ply("Medicine Ball Slam", "full_body", ["abdominals", "shoulders", "lats"], "medicine_ball", tracking="weight_reps", aliases=["Ball Slam", "Slam Ball"])
ply("Medicine Ball Chest Pass", "chest", ["triceps", "shoulders"], "medicine_ball", tracking="weight_reps")
ply("Medicine Ball Overhead Throw", "shoulders", ["abdominals", "lats"], "medicine_ball", tracking="weight_reps")
ply("Rotational Medicine Ball Throw", "obliques", ["shoulders", "glutes"], "medicine_ball", tracking="weight_reps", aliases=["Med Ball Scoop Toss"])
ply("Clapping Pull-Up", "lats", ["biceps"])
ex("Jumping Jack", "full_body", ["shoulders", "calves"], category="cardio", aliases=["Jumping Jacks"])
ex("High Knees", "cardio", ["quadriceps", "abdominals"], category="cardio", tracking="duration")
ex("Butt Kicks", "cardio", ["hamstrings"], category="cardio", tracking="duration")
ex("A-Skip", "cardio", ["hamstrings", "calves"], category="cardio", tracking="short_distance")
ex("B-Skip", "cardio", ["hamstrings", "calves"], category="cardio", tracking="short_distance")
ex("Double-Under", "calves", ["shoulders", "forearms"], "jump_rope", category="cardio", tracking="reps", aliases=["DU", "Double Unders"])
ex("Single-Under", "calves", ["shoulders"], "jump_rope", category="cardio", tracking="reps", aliases=["Single Unders", "Jump Rope Reps"])
ex("Jump Rope", "cardio", ["calves"], "jump_rope", category="cardio", tracking="duration", aliases=["Skipping Rope", "Skipping"])
ex("Shuttle Run", "cardio", ["quadriceps"], category="cardio", tracking="short_distance", aliases=["Suicides", "Shuttle Sprint"])
ex("Battle Rope Waves", "shoulders", ["abdominals", "forearms"], "battle_rope", category="cardio", tracking="duration", aliases=["Battle Ropes"])
ex("Battle Rope Slams", "shoulders", ["abdominals", "lats"], "battle_rope", category="cardio", tracking="duration")

# ---------------------------------------------------------------- Strongman
def sm(name, primary, secondary=(), equipment=None, tracking=None, aliases=()):
    if equipment is None and not re.search(r"\(([^)]+)\)$", name):
        equipment = "other"
    ex(name, primary, list(secondary), equipment, category="strongman", tracking=tracking, aliases=aliases)

sm("Atlas Stone Lift", "full_body", ["glutes", "lower_back", "biceps"], aliases=["Stone to Platform", "Atlas Stones"])
sm("Stone to Shoulder", "full_body", ["glutes", "lower_back", "biceps"])
sm("Yoke Walk", "full_body", ["quadriceps", "abdominals", "traps"], tracking="weight_distance", aliases=["Yoke Carry"])
sm("Log Press", "shoulders", ["triceps", "upper_back"])
sm("Log Clean and Press", "full_body", ["shoulders", "triceps", "lower_back"])
sm("Axle Deadlift", "lower_back", ["glutes", "hamstrings", "forearms"], aliases=["Fat Bar Deadlift"])
sm("Axle Press", "shoulders", ["triceps"], aliases=["Axle Clean and Press"])
sm("Frame Carry", "full_body", ["forearms", "traps"], tracking="weight_distance")
sm("Keg Carry", "full_body", ["biceps", "abdominals"], tracking="weight_distance")
sm("Keg Toss", "full_body", ["glutes", "shoulders"])
sm("Sandbag Carry", "full_body", ["biceps", "abdominals"], "sandbag", tracking="weight_distance", aliases=["Bear Hug Carry"])
sm("Sandbag Clean", "full_body", ["glutes", "biceps"], "sandbag")
sm("Sandbag Over Shoulder", "full_body", ["glutes", "lower_back"], "sandbag", aliases=["Sandbag to Shoulder"])
sm("Bear Hug Squat (Sandbag)", "quadriceps", ["glutes", "abdominals"], "sandbag")
sm("Tire Flip", "full_body", ["glutes", "quadriceps", "chest"])
sm("Sled Rope Pull", "lats", ["biceps", "forearms"], "sled", tracking="weight_distance", aliases=["Arm-Over-Arm Pull"])
sm("Husafell Stone Carry", "full_body", ["biceps", "abdominals"], tracking="weight_distance")
sm("Circus Dumbbell Press", "shoulders", ["triceps", "obliques"], "dumbbell")
sm("Conan's Wheel", "full_body", ["abdominals", "biceps"], tracking="weight_distance")
sm("Truck Pull", "full_body", ["quadriceps", "glutes"], tracking="weight_distance")
sm("Car Deadlift", "lower_back", ["glutes", "hamstrings", "traps"])
sm("Sledgehammer Strike", "full_body", ["obliques", "shoulders"], tracking="reps", aliases=["Tire Slam", "Sledgehammer Slam"])

# ---------------------------------------------------------------- Calisthenics skills & holds
def cal(name, primary, secondary=(), tracking="duration", equipment=None, aliases=()):
    ex(name, primary, list(secondary), equipment, category="calisthenics", tracking=tracking, aliases=aliases)

cal("Front Lever", "lats", ["abdominals", "shoulders"])
cal("Tuck Front Lever", "lats", ["abdominals"])
cal("Front Lever Raise", "lats", ["abdominals"], tracking="reps")
cal("Back Lever", "lats", ["chest", "biceps", "shoulders"])
cal("Planche", "shoulders", ["chest", "triceps", "abdominals"])
cal("Tuck Planche", "shoulders", ["chest", "triceps"])
cal("Planche Lean", "shoulders", ["chest", "abdominals"])
cal("Human Flag", "obliques", ["shoulders", "lats"])
cal("Ring Support Hold", "triceps", ["chest", "shoulders"], equipment="rings")
cal("German Hang", "shoulders", ["chest", "biceps"])
cal("Skin the Cat", "shoulders", ["lats", "abdominals"], tracking="reps")
cal("Headstand", "shoulders", ["abdominals"])
cal("Crow Pose", "shoulders", ["abdominals", "triceps"])
cal("Bridge Hold", "lower_back", ["shoulders", "glutes"], aliases=["Wheel Pose", "Back Bridge"])

# ---------------------------------------------------------------- Cardio
def cardio(name, equipment=None, tracking="distance_duration", aliases=(), primary="cardio", secondary=(), category="cardio"):
    ex(name, primary, list(secondary), equipment, category=category, tracking=tracking, aliases=aliases)

cardio("Running", aliases=["Run", "Jog", "Jogging", "Outdoor Run"])
cardio("Treadmill Run", "cardio_machine", aliases=["Treadmill"])
cardio("Walking", aliases=["Walk"])
cardio("Treadmill Walk", "cardio_machine")
cardio("Incline Treadmill Walk", "cardio_machine", aliases=["12-3-30", "Incline Walk"])
cardio("Hiking", aliases=["Hike"])
cardio("Trail Running", aliases=["Trail Run"])
cardio("Sprint", tracking="short_distance", aliases=["Sprints", "Dash"])
cardio("Hill Sprint", tracking="short_distance", aliases=["Hill Sprints"])
cardio("Rucking", "other", tracking="weight_distance", aliases=["Ruck", "Weighted Walk"])
cardio("Cycling", aliases=["Bike", "Outdoor Cycling", "Road Cycling", "Bike Ride"])
cardio("Mountain Biking", aliases=["MTB"])
cardio("Stationary Bike", "cardio_machine", aliases=["Exercise Bike", "Indoor Cycling", "Bike Erg", "BikeErg"])
cardio("Spin Bike", "cardio_machine", aliases=["Spin Class", "Spinning"])
cardio("Assault Bike", "cardio_machine", aliases=["Air Bike", "Echo Bike", "AirDyne", "Fan Bike"])
cardio("Recumbent Bike", "cardio_machine")
cardio("Rowing Machine", "cardio_machine", aliases=["Rower", "Erg", "Concept2", "Row", "Indoor Rowing"])
cardio("Ski Erg", "cardio_machine", aliases=["SkiErg", "Ski Ergometer"])
cardio("Elliptical", "cardio_machine", aliases=["Cross Trainer", "Elliptical Trainer"])
cardio("Stair Climber", "cardio_machine", tracking="duration", aliases=["StairMaster", "Stepmill", "Stair Stepper"])
cardio("Stair Running", tracking="duration", aliases=["Stairs", "Stadium Stairs"])
cardio("Swimming", aliases=["Swim", "Freestyle Swim", "Lap Swimming"])
cardio("Breaststroke", aliases=["Breaststroke Swim"])
cardio("Backstroke", aliases=["Backstroke Swim"])
cardio("Butterfly Stroke", aliases=["Butterfly Swim"])
cardio("Open Water Swim")
cardio("Water Aerobics", tracking="duration")
cardio("Inline Skating", aliases=["Rollerblading"])
cardio("Ice Skating")
cardio("Cross-Country Skiing", aliases=["Nordic Skiing"])
cardio("Snowshoeing")
cardio("Shadow Boxing", tracking="duration")
cardio("Heavy Bag", "other", tracking="duration", aliases=["Punching Bag", "Bag Work"])
cardio("HIIT", tracking="duration", aliases=["High-Intensity Interval Training"], primary="full_body")
cardio("Circuit Training", tracking="duration", primary="full_body")
cardio("Aerobics", tracking="duration")
cardio("Step Aerobics", "other", tracking="duration")
cardio("Dancing", tracking="duration", aliases=["Dance", "Zumba"])

# ---------------------------------------------------------------- Sports & activities
def sport(name, aliases=(), primary="full_body", tracking="duration"):
    ex(name, primary, [], "none" if tracking == "duration" else "other", category="sport", tracking=tracking, aliases=aliases)

for name, aliases in [
    ("Basketball", ["Hoops"]), ("Soccer", ["Football", "Futsal"]), ("American Football", ["Gridiron"]),
    ("Tennis", []), ("Pickleball", []), ("Padel", []), ("Badminton", []), ("Squash", []), ("Racquetball", []),
    ("Table Tennis", ["Ping Pong"]), ("Volleyball", []), ("Beach Volleyball", []), ("Baseball", []), ("Softball", []),
    ("Cricket", []), ("Golf", []), ("Ice Hockey", ["Hockey"]), ("Field Hockey", []), ("Lacrosse", []), ("Rugby", []),
    ("Handball", []), ("Ultimate Frisbee", ["Ultimate"]), ("Surfing", []), ("Skateboarding", []), ("Snowboarding", []),
    ("Downhill Skiing", ["Skiing", "Alpine Skiing"]), ("Horseback Riding", ["Equestrian"]), ("Rock Climbing", ["Climbing", "Sport Climbing"]),
    ("Bouldering", []), ("Boxing", ["Sparring"]), ("Kickboxing", []), ("Muay Thai", []), ("Brazilian Jiu-Jitsu", ["BJJ", "Jiu Jitsu", "Grappling"]),
    ("Wrestling", []), ("Mixed Martial Arts", ["MMA"]), ("Karate", []), ("Judo", []), ("Taekwondo", []), ("Fencing", []),
    ("Gymnastics", []), ("Kayaking", []), ("Canoeing", []), ("Stand-Up Paddleboarding", ["SUP", "Paddleboarding"]),
    ("Rowing (On Water)", ["Crew", "Sculling"]),
]:
    sport(name, aliases)

# ---------------------------------------------------------------- Mobility & recovery
def mob(name, primary, secondary=(), tracking="duration", equipment=None, aliases=()):
    ex(name, primary, list(secondary), equipment, category="mobility", tracking=tracking, aliases=aliases)

mob("Yoga", "full_body", aliases=["Vinyasa", "Hatha"])
mob("Pilates", "abdominals", ["glutes"], aliases=["Mat Pilates", "Reformer Pilates"])
mob("Barre", "glutes", ["quadriceps", "abdominals"])
mob("Tai Chi", "full_body")
mob("Stretching", "full_body", aliases=["Stretch", "Static Stretching"])
mob("Sun Salutation", "full_body", aliases=["Surya Namaskar"])
for area, primary in [("Quads", "quadriceps"), ("Hamstrings", "hamstrings"), ("IT Band", "quadriceps"), ("Glutes", "glutes"),
                      ("Calves", "calves"), ("Adductors", "adductors"), ("Upper Back", "upper_back"), ("Lats", "lats"), ("Chest", "chest")]:
    mob(f"Foam Roll {area}", primary, equipment="foam_roller", aliases=["Foam Rolling", "Myofascial Release"])
mob("Lacrosse Ball Release", "full_body", equipment="other", aliases=["Trigger Point", "Massage Ball"])
mob("Massage Gun", "full_body", equipment="other", aliases=["Percussion Massage", "Theragun"])
mob("Couch Stretch", "quadriceps", ["glutes"], aliases=["Hip Flexor Stretch"])
mob("Kneeling Hip Flexor Stretch", "quadriceps", ["glutes"], aliases=["Half-Kneeling Hip Flexor Stretch"])
mob("Standing Quad Stretch", "quadriceps")
mob("Standing Hamstring Stretch", "hamstrings")
mob("Seated Hamstring Stretch", "hamstrings", ["lower_back"])
mob("Standing Forward Fold", "hamstrings", ["lower_back"], aliases=["Toe Touch Stretch", "Uttanasana"])
mob("Pigeon Pose", "glutes", ["adductors"], aliases=["Pigeon Stretch"])
mob("90/90 Hip Stretch", "glutes", ["adductors"], aliases=["90-90 Stretch", "Shin Box"])
mob("Figure-4 Stretch", "glutes", aliases=["Figure Four Stretch"])
mob("Lizard Pose", "glutes", ["adductors", "quadriceps"])
mob("Butterfly Stretch", "adductors", aliases=["Seated Butterfly"])
mob("Frog Stretch", "adductors", ["glutes"])
mob("Pancake Stretch", "adductors", ["hamstrings"], aliases=["Straddle Stretch"])
mob("Deep Squat Hold", "glutes", ["quadriceps", "calves"], aliases=["Squat Hold", "Malasana"])
mob("Happy Baby", "lower_back", ["glutes", "adductors"])
mob("Child's Pose", "lower_back", ["lats", "shoulders"], aliases=["Balasana"])
mob("Supine Spinal Twist", "lower_back", ["obliques", "glutes"], aliases=["Lying Twist"])
mob("Cobra Stretch", "abdominals", ["lower_back"], aliases=["Cobra Pose", "Upward Dog"])
mob("Downward Dog", "hamstrings", ["calves", "shoulders"], aliases=["Downward-Facing Dog"])
mob("Cat-Cow", "lower_back", ["abdominals"], tracking="reps", aliases=["Cat Cow"])
mob("World's Greatest Stretch", "full_body", ["glutes", "hamstrings"], tracking="reps", aliases=["WGS"])
mob("Spiderman Lunge with Rotation", "full_body", ["glutes", "upper_back"], tracking="reps")
mob("Scorpion Stretch", "lower_back", ["glutes"], tracking="reps")
mob("Thoracic Rotation", "upper_back", ["obliques"], tracking="reps", aliases=["T-Spine Rotation", "Open Book"])
mob("Thread the Needle", "upper_back", ["shoulders"], tracking="reps")
mob("Wall Slide", "shoulders", ["upper_back"], tracking="reps", aliases=["Wall Angels"])
mob("Shoulder Dislocate", "shoulders", ["chest"], tracking="reps", equipment="band", aliases=["Pass-Through", "Band Pass-Through"])
mob("Doorway Chest Stretch", "chest", ["shoulders"], aliases=["Pec Stretch"])
mob("Cross-Body Shoulder Stretch", "shoulders", ["upper_back"])
mob("Sleeper Stretch", "shoulders")
mob("Overhead Triceps Stretch", "triceps", ["lats"])
mob("Lat Stretch", "lats", ["shoulders"])
mob("Standing Calf Stretch", "calves", aliases=["Wall Calf Stretch"])
mob("Knee-to-Wall Ankle Mobilization", "calves", tracking="reps", aliases=["Ankle Mobility", "Ankle Dorsiflexion"])
mob("Neck Stretch", "neck", ["traps"])
mob("Wrist Stretch", "forearms")
mob("Hip Circles", "glutes", ["adductors", "abductors"], tracking="reps")
mob("Leg Swings", "hamstrings", ["adductors", "glutes"], tracking="reps")
mob("Arm Circles", "shoulders", tracking="reps")
mob("Sauna", "other", aliases=["Steam Room"])
mob("Cold Plunge", "other", aliases=["Ice Bath", "Cold Water Immersion"])


def main():
    root = Path(__file__).resolve().parent.parent
    out = root / "App" / "Resources" / "exercises.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    ordered = sorted(EXERCISES, key=lambda e: e["name"].lower())
    data = {"version": CATALOG_VERSION, "exercises": ordered}
    text = json.dumps(data, ensure_ascii=False, indent=1, sort_keys=False)
    # One exercise per line keeps diffs readable.
    compact = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    lines = ['{"version":%d,"exercises":[' % CATALOG_VERSION]
    for index, entry in enumerate(ordered):
        suffix = "," if index < len(ordered) - 1 else ""
        lines.append(json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + suffix)
    lines.append("]}")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    assert json.loads(out.read_text(encoding="utf-8")) == json.loads(compact)
    by_category = {}
    for entry in EXERCISES:
        key = entry.get("category", "strength")
        by_category[key] = by_category.get(key, 0) + 1
    print(f"Wrote {len(EXERCISES)} exercises to {out.relative_to(root)}")
    for key in sorted(by_category):
        print(f"  {key:13} {by_category[key]}")
    del text


if __name__ == "__main__":
    main()
