import Foundation

/// The picture for an exercise: a drawn glyph, or one of the sport and
/// cardio figures iOS ships as symbols, with a glyph to fall back on.
public enum ExerciseIcon: Hashable, Sendable {
    case glyph(ExerciseGlyph)
    /// System symbol names, best first; the glyph shows if none exist.
    case symbol([String], fallback: ExerciseGlyph)
}

extension Exercise {
    /// Its equipment for anything that uses some (a kettlebell for every
    /// kettlebell exercise), the movement itself for bodyweight exercises,
    /// and the sport's own figure for sports and cardio.
    public var icon: ExerciseIcon { ExerciseIcon.for(self) }
}

extension ExerciseIcon {
    public static func `for`(_ exercise: Exercise) -> ExerciseIcon {
        let name = exercise.name.lowercased().replacingOccurrences(of: "’", with: "'")
        switch exercise.equipment {
        case .dumbbell: return .glyph(.dumbbell)
        case .kettlebell: return .glyph(.kettlebell)
        case .barbell: return .glyph(.barbell)
        case .ezBar: return .glyph(.ezBar)
        case .trapBar: return .glyph(.trapBar)
        case .smithMachine: return .glyph(.smithMachine)
        case .machine: return .glyph(.machine)
        case .cable: return .glyph(.cable)
        case .band: return .glyph(.band)
        case .plate: return .glyph(.plate)
        case .landmine: return .glyph(.landmine)
        case .medicineBall: return .glyph(.medicineBall)
        case .stabilityBall: return .glyph(.stabilityBall)
        case .foamRoller: return .glyph(.foamRoller)
        case .suspension: return .glyph(.suspension)
        case .rings: return .glyph(.rings)
        case .sled: return .glyph(.sled)
        case .sandbag: return .glyph(.sandbag)
        case .jumpRope: return .glyph(.jumpRope)
        case .battleRope: return .glyph(.battleRope)
        case .cardioMachine:
            return cardioMachine(name)
        case .other:
            return first(otherRules, in: name) ?? bodyweight(name, category: exercise.category)
        case .none:
            return bodyweight(name, category: exercise.category)
        }
    }

    // MARK: Rules

    /// Sports and activities, then movements, then the category's figure.
    static func bodyweight(_ name: String, category: ExerciseCategory) -> ExerciseIcon {
        if let exact = exactActivities[name] { return exact }
        if let activity = first(activityRules, in: name) { return activity }
        for rule in movementRules where rule.words.contains(where: name.contains) {
            return .glyph(rule.glyph)
        }
        switch category {
        case .cardio: return .symbol(["figure.mixed.cardio"], fallback: .run)
        case .sport: return .symbol(["figure.mixed.cardio"], fallback: .stand)
        case .mobility: return .glyph(.sideStretch)
        case .plyometric: return .glyph(.jump)
        case .calisthenics: return .glyph(.pushUp)
        case .strength, .olympic, .strongman: return .glyph(.stand)
        }
    }

    static func cardioMachine(_ name: String) -> ExerciseIcon {
        first(cardioMachineRules, in: name) ?? .symbol(["figure.mixed.cardio"], fallback: .run)
    }

    private static func first(_ rules: [(words: [String], icon: ExerciseIcon)], in name: String) -> ExerciseIcon? {
        rules.first { $0.words.contains(where: name.contains) }?.icon
    }

    /// Names that are also words inside longer ones ("walking" in
    /// "Walking Lunge"), matched whole.
    static let exactActivities: [String: ExerciseIcon] = [
        "walking": .symbol(["figure.walk"], fallback: .run),
        "running": .symbol(["figure.run"], fallback: .run),
        "sprint": .symbol(["figure.run"], fallback: .run),
        "swimming": .symbol(["figure.pool.swim"], fallback: .stand),
        "cycling": .symbol(["figure.outdoor.cycle"], fallback: .stand),
        "hiking": .symbol(["figure.hiking"], fallback: .run),
    ]

    static let activityRules: [(words: [String], icon: ExerciseIcon)] = [
        (["american football"], .symbol(["figure.american.football"], fallback: .run)),
        (["badminton"], .symbol(["figure.badminton"], fallback: .stand)),
        (["softball"], .symbol(["figure.softball", "figure.baseball"], fallback: .stand)),
        (["baseball"], .symbol(["figure.baseball"], fallback: .stand)),
        (["basketball"], .symbol(["figure.basketball"], fallback: .jump)),
        (["volleyball"], .symbol(["figure.volleyball"], fallback: .jump)),
        (["kickboxing", "muay thai"], .symbol(["figure.kickboxing"], fallback: .stand)),
        (["boxing"], .symbol(["figure.boxing"], fallback: .stand)),
        (["jiu-jitsu", "judo", "wrestling"], .symbol(["figure.wrestling"], fallback: .stand)),
        (["karate", "taekwondo", "martial arts"], .symbol(["figure.martial.arts"], fallback: .stand)),
        (["bouldering", "rock climbing"], .symbol(["figure.climbing"], fallback: .hang)),
        (["rowing (on water)"], .symbol(["figure.outdoor.rowing", "figure.rower"], fallback: .stand)),
        (["canoe", "kayak", "paddleboard"], .symbol(["figure.outdoor.rowing", "oar.2.crossed"], fallback: .stand)),
        (["cricket"], .symbol(["figure.cricket"], fallback: .stand)),
        (["cross-country skiing"], .symbol(["figure.skiing.crosscountry"], fallback: .run)),
        (["downhill skiing"], .symbol(["figure.skiing.downhill"], fallback: .squat)),
        (["snowboarding"], .symbol(["figure.snowboarding"], fallback: .squat)),
        (["snowshoe", "rucking"], .symbol(["figure.hiking"], fallback: .run)),
        (["mountain biking", "cycling"], .symbol(["figure.outdoor.cycle"], fallback: .stand)),
        (["water aerobics"], .symbol(["figure.water.fitness"], fallback: .stand)),
        (["step aerobics"], .symbol(["figure.step.training"], fallback: .stepUp)),
        (["aerobics"], .symbol(["figure.step.training", "figure.dance"], fallback: .jumpingJack)),
        (["dancing"], .symbol(["figure.dance"], fallback: .stand)),
        (["barre"], .symbol(["figure.barre"], fallback: .stand)),
        (["pilates"], .symbol(["figure.pilates"], fallback: .hollowHold)),
        (["sun salutation", "yoga"], .symbol(["figure.yoga"], fallback: .downwardDog)),
        (["tai chi"], .symbol(["figure.taichi"], fallback: .stand)),
        (["gymnastics"], .symbol(["figure.gymnastics"], fallback: .handstand)),
        (["fencing"], .symbol(["figure.fencing"], fallback: .lunge)),
        (["hockey"], .symbol(["figure.hockey"], fallback: .run)),
        (["golf"], .symbol(["figure.golf"], fallback: .stand)),
        (["handball"], .symbol(["figure.handball"], fallback: .run)),
        (["horseback"], .symbol(["figure.equestrian.sports"], fallback: .stand)),
        (["ice skating", "inline skating"], .symbol(["figure.skating"], fallback: .run)),
        (["skateboard"], .symbol(["figure.skateboarding", "figure.skating"], fallback: .stand)),
        (["lacrosse"], .symbol(["figure.lacrosse"], fallback: .run)),
        (["pickleball"], .symbol(["figure.pickleball", "figure.tennis"], fallback: .stand)),
        (["table tennis"], .symbol(["figure.table.tennis"], fallback: .stand)),
        (["racquetball"], .symbol(["figure.racquetball", "figure.squash"], fallback: .stand)),
        (["squash"], .symbol(["figure.squash"], fallback: .stand)),
        (["padel", "tennis"], .symbol(["figure.tennis"], fallback: .stand)),
        (["rugby"], .symbol(["figure.rugby"], fallback: .run)),
        (["soccer"], .symbol(["figure.soccer"], fallback: .run)),
        (["frisbee"], .symbol(["figure.disc.sports"], fallback: .run)),
        (["surfing"], .symbol(["figure.surfing"], fallback: .squat)),
        (["open water swim"], .symbol(["figure.open.water.swim"], fallback: .stand)),
        (["backstroke", "breaststroke", "butterfly stroke", "swim"], .symbol(["figure.pool.swim"], fallback: .stand)),
        (["sauna"], .symbol(["flame"], fallback: .stand)),
        (["cold plunge"], .symbol(["snowflake"], fallback: .stand)),
        (["stair running"], .symbol(["figure.stairs"], fallback: .stepUp)),
        (["trail running", "hill sprint", "shuttle run"], .symbol(["figure.run"], fallback: .run)),
        (["hiit"], .symbol(["figure.highintensity.intervaltraining"], fallback: .burpee)),
        (["circuit training"], .symbol(["figure.cross.training"], fallback: .burpee)),
        (["stretching"], .symbol(["figure.flexibility"], fallback: .sideStretch)),
    ]

    static let cardioMachineRules: [(words: [String], icon: ExerciseIcon)] = [
        (["bike"], .symbol(["figure.indoor.cycle"], fallback: .stand)),
        (["elliptical"], .symbol(["figure.elliptical"], fallback: .run)),
        (["rowing"], .symbol(["figure.rower"], fallback: .stand)),
        (["ski erg"], .symbol(["figure.skiing.crosscountry"], fallback: .run)),
        (["stair"], .symbol(["figure.stair.stepper"], fallback: .stepUp)),
        (["incline"], .symbol(["figure.hiking"], fallback: .run)),
        (["walk"], .symbol(["figure.walk"], fallback: .run)),
        (["run"], .symbol(["figure.run"], fallback: .run)),
    ]

    /// Strongman gear, plyo boxes and the other odd kit.
    static let otherRules: [(words: [String], icon: ExerciseIcon)] = [
        (["box jump", "depth jump"], .glyph(.boxJump)),
        (["step aerobics"], .symbol(["figure.step.training"], fallback: .stepUp)),
        (["stone", "conan"], .glyph(.stone)),
        (["log "], .glyph(.log)),
        (["tire"], .glyph(.tire)),
        (["keg"], .glyph(.keg)),
        (["yoke"], .glyph(.yoke)),
        (["sledgehammer"], .glyph(.sledgehammer)),
        (["farmer", "frame carry"], .glyph(.farmerHandles)),
        (["axle"], .glyph(.barbell)),
        (["car deadlift"], .symbol(["car.side"], fallback: .barbell)),
        (["truck pull"], .symbol(["truck.box"], fallback: .sled)),
        (["ab wheel"], .glyph(.abWheel)),
        (["rope climb"], .glyph(.climbingRope)),
        (["heavy bag"], .glyph(.heavyBag)),
        (["gripper", "wrist roller"], .glyph(.gripper)),
        (["massage gun"], .glyph(.massageGun)),
        (["lacrosse ball"], .glyph(.medicineBall)),
        (["neck harness"], .glyph(.plate)),
        (["slider"], .glyph(.slider)),
        (["rucking"], .symbol(["figure.hiking"], fallback: .run)),
    ]

    /// Checked in order: more specific movements first ("hanging leg raise"
    /// before "leg raise", "jump squat" before "squat").
    static let movementRules: [(words: [String], glyph: ExerciseGlyph)] = [
        (["handstand", "headstand", "wall walk"], .handstand),
        (["muscle-up"], .muscleUp),
        (["front lever", "back lever", "human flag", "skin the cat"], .frontLever),
        (["planche", "crow pose"], .planche),
        (["v-sit", "v-up", "jackknife"], .vUp),
        (["hanging knee raise", "hanging leg raise", "toes-to-bar", "knees-to-elbows", "windshield wiper"], .hangingLegRaise),
        (["dead hang", "active hang", "german hang", "scapular pull-up"], .hang),
        (["pull-up", "chin-up"], .pullUp),
        (["l-sit"], .lSit),
        (["inverted row"], .invertedRow),
        (["bench dip"], .benchDip),
        (["dip"], .dip),
        (["mountain climber"], .mountainClimber),
        (["side plank", "copenhagen"], .sidePlank),
        (["burpee", "sprawl"], .burpee),
        (["push-up", "pushup", "triceps extension"], .pushUp),
        (["plank"], .plank),
        (["bear crawl"], .bearCrawl),
        (["jumping jack", "star jump"], .jumpingJack),
        (["box jump", "depth jump"], .boxJump),
        (["high knees", "a-skip", "b-skip"], .highKnees),
        (["butt kick"], .buttKicks),
        (["jump", "hop", "bounding"], .jump),
        (["pistol"], .pistolSquat),
        (["wall sit"], .wallSit),
        (["cossack", "lateral lunge", "side lunge"], .lateralLunge),
        (["hip flexor", "couch stretch", "lizard", "world's greatest", "pigeon", "spiderman lunge"], .lungeStretch),
        (["lunge", "split squat"], .lunge),
        (["squat"], .squat),
        (["step-up", "step up"], .stepUp),
        (["calf raise", "tibialis"], .calfRaise),
        (["nordic"], .nordicCurl),
        (["hip thrust"], .hipThrust),
        (["bridge", "frog pump"], .gluteBridge),
        (["romanian deadlift", "good morning"], .hinge),
        (["back extension", "superman"], .superman),
        (["bird dog"], .birdDog),
        (["donkey kick", "fire hydrant", "kickback"], .donkeyKick),
        (["clamshell", "side-lying"], .sideLying),
        (["hollow"], .hollowHold),
        (["dead bug"], .deadBug),
        (["sit-up"], .sitUp),
        (["crunch", "heel touch"], .crunch),
        (["russian twist"], .russianTwist),
        (["leg raise", "flutter kick", "scissor kick", "dragon flag"], .legRaise),
        (["downward dog"], .downwardDog),
        (["child's pose", "thread the needle"], .childsPose),
        (["cobra"], .cobra),
        (["cat-cow", "cat cow", "thoracic rotation"], .catCow),
        (["forward fold", "toe touch", "standing hamstring"], .forwardFold),
        (["seated hamstring", "pancake", "butterfly stretch", "frog stretch", "90/90"], .seatedStretch),
        (["figure-4", "happy baby", "spinal twist", "knee to chest", "knee-to-chest"], .kneeHug),
        (["quad stretch"], .quadStretch),
        (["calf stretch", "ankle"], .calfStretch),
        (["leg swing", "hip circle"], .legSwing),
        (["arm circle", "wall slide", "shoulder dislocate"], .armCircles),
        (["stretch"], .sideStretch),
        (["walk", "run", "sprint"], .run),
    ]
}
