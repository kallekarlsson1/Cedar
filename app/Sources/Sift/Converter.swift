import Foundation

/// "100 usd", "$100 to eur", "500 kr in usd", "5 km in miles", "20 c to f".
/// Exchange rates are the European Central Bank's daily reference rates (via frankfurter.dev): downloaded at most a few
/// times a day, kept on disk, and never sent anything about what you type.
final class Converter {
    struct Result { let text: String; let result: String; let copy: String; let note: String }

    private(set) var rates: [String: Double] = [:]   // per 1 EUR
    private(set) var ratesDate = ""
    private let ratesFile: URL
    private let home: String = Locale.current.currency?.identifier ?? "USD"

    init(dataDir: URL) {
        ratesFile = dataDir.appendingPathComponent("rates.json")
        load()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: rates

    private struct RatesFile: Codable { let date: String; let rates: [String: Double]; var fetched: Double? }

    private func load() {
        guard let data = try? Data(contentsOf: ratesFile),
              let file = try? JSONDecoder().decode(RatesFile.self, from: data) else { return }
        rates = file.rates
        rates["EUR"] = 1
        ratesDate = file.date
    }

    func refresh() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: ratesFile.path),
           let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 6 * 3600 { return }
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=EUR") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let file = try? JSONDecoder().decode(RatesFile.self, from: data),
                  !file.rates.isEmpty else { return }
            try? data.write(to: self.ratesFile, options: .atomic)
            DispatchQueue.main.async {
                self.rates = file.rates
                self.rates["EUR"] = 1
                self.ratesDate = file.date
            }
        }.resume()
    }

    // MARK: parsing

    private static let currencyNames: [String: String] = [
        "$": "USD", "usd": "USD", "dollar": "USD", "dollars": "USD", "us$": "USD",
        "€": "EUR", "eur": "EUR", "euro": "EUR", "euros": "EUR",
        "£": "GBP", "gbp": "GBP", "pound": "GBP", "pounds": "GBP", "quid": "GBP",
        "¥": "JPY", "jpy": "JPY", "yen": "JPY",
        "kr": "SEK", "sek": "SEK", "kronor": "SEK", "krona": "SEK", "kronur": "ISK",
        "nok": "NOK", "dkk": "DKK", "chf": "CHF", "franc": "CHF", "francs": "CHF",
        "cny": "CNY", "yuan": "CNY", "rmb": "CNY", "inr": "INR", "rupee": "INR", "rupees": "INR", "₹": "INR",
        "cad": "CAD", "aud": "AUD", "nzd": "NZD", "pln": "PLN", "zloty": "PLN", "czk": "CZK", "huf": "HUF",
        "isk": "ISK", "try": "TRY", "lira": "TRY", "krw": "KRW", "won": "KRW", "₩": "KRW", "brl": "BRL",
        "real": "BRL", "reais": "BRL", "mxn": "MXN", "zar": "ZAR", "rand": "ZAR", "sgd": "SGD", "hkd": "HKD",
        "thb": "THB", "baht": "THB", "ils": "ILS", "shekel": "ILS", "idr": "IDR", "myr": "MYR", "php": "PHP",
        "ron": "RON",
    ]

    private static let units: [String: Unit] = {
        var u: [String: Unit] = [:]
        func add(_ names: [String], _ unit: Unit) { for n in names { u[n] = unit } }
        add(["m", "meter", "meters", "metre", "metres", "meter"], UnitLength.meters)
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres", "kilometer"], UnitLength.kilometers)
        add(["cm", "centimeter", "centimeters"], UnitLength.centimeters)
        add(["mm", "millimeter", "millimeters"], UnitLength.millimeters)
        add(["mi", "mile", "miles"], UnitLength.miles)
        add(["mil"], UnitLength.scandinavianMiles)
        add(["ft", "foot", "feet", "'"], UnitLength.feet)
        add(["in", "inch", "inches", "\""], UnitLength.inches)
        add(["yd", "yard", "yards"], UnitLength.yards)
        add(["nmi", "nauticalmile", "nauticalmiles"], UnitLength.nauticalMiles)
        add(["kg", "kilo", "kilos", "kilogram", "kilograms"], UnitMass.kilograms)
        add(["g", "gram", "grams"], UnitMass.grams)
        add(["mg"], UnitMass.milligrams)
        add(["lb", "lbs"], UnitMass.pounds)
        add(["oz", "ounce", "ounces"], UnitMass.ounces)
        add(["st", "stone", "stones"], UnitMass.stones)
        add(["t", "ton", "tonne", "tonnes"], UnitMass.metricTons)
        add(["c", "°c", "celsius", "degc"], UnitTemperature.celsius)
        add(["f", "°f", "fahrenheit", "degf"], UnitTemperature.fahrenheit)
        add(["k", "kelvin"], UnitTemperature.kelvin)
        add(["l", "liter", "liters", "litre", "litres"], UnitVolume.liters)
        add(["dl"], UnitVolume.deciliters)
        add(["cl"], UnitVolume.centiliters)
        add(["ml"], UnitVolume.milliliters)
        add(["gal", "gallon", "gallons"], UnitVolume.gallons)
        add(["cup", "cups"], UnitVolume.cups)
        add(["floz"], UnitVolume.fluidOunces)
        add(["tbsp", "msk"], UnitVolume.tablespoons)
        add(["tsp", "tsk"], UnitVolume.teaspoons)
        add(["kmh", "km/h", "kph"], UnitSpeed.kilometersPerHour)
        add(["mph"], UnitSpeed.milesPerHour)
        add(["m/s", "mps"], UnitSpeed.metersPerSecond)
        add(["knot", "knots", "kn"], UnitSpeed.knots)
        add(["b", "byte", "bytes"], UnitInformationStorage.bytes)
        add(["kb"], UnitInformationStorage.kilobytes)
        add(["mb"], UnitInformationStorage.megabytes)
        add(["gb"], UnitInformationStorage.gigabytes)
        add(["tb"], UnitInformationStorage.terabytes)
        add(["s", "sec", "secs", "second", "seconds"], UnitDuration.seconds)
        add(["min", "mins", "minute", "minutes"], UnitDuration.minutes)
        add(["h", "hr", "hrs", "hour", "hours"], UnitDuration.hours)
        add(["m2", "sqm", "m²"], UnitArea.squareMeters)
        add(["km2", "km²"], UnitArea.squareKilometers)
        add(["ft2", "sqft", "ft²"], UnitArea.squareFeet)
        add(["acre", "acres"], UnitArea.acres)
        add(["ha", "hectare", "hectares"], UnitArea.hectares)
        add(["kcal", "calories", "cal"], UnitEnergy.kilocalories)
        add(["kj"], UnitEnergy.kilojoules)
        add(["kwh"], UnitEnergy.kilowattHours)
        return u
    }()

    /// What a unit converts to when no target is typed.
    private static let defaultTarget: [Unit: Unit] = [
        UnitLength.kilometers: UnitLength.miles, UnitLength.miles: UnitLength.kilometers,
        UnitLength.meters: UnitLength.feet, UnitLength.feet: UnitLength.meters,
        UnitLength.centimeters: UnitLength.inches, UnitLength.inches: UnitLength.centimeters,
        UnitLength.millimeters: UnitLength.inches, UnitLength.yards: UnitLength.meters,
        UnitLength.scandinavianMiles: UnitLength.kilometers, UnitLength.nauticalMiles: UnitLength.kilometers,
        UnitMass.kilograms: UnitMass.pounds, UnitMass.pounds: UnitMass.kilograms, UnitMass.grams: UnitMass.ounces,
        UnitMass.ounces: UnitMass.grams, UnitMass.stones: UnitMass.kilograms, UnitMass.metricTons: UnitMass.pounds,
        UnitMass.milligrams: UnitMass.grams,
        UnitTemperature.celsius: UnitTemperature.fahrenheit, UnitTemperature.fahrenheit: UnitTemperature.celsius,
        UnitTemperature.kelvin: UnitTemperature.celsius,
        UnitVolume.liters: UnitVolume.gallons, UnitVolume.gallons: UnitVolume.liters, UnitVolume.cups: UnitVolume.deciliters,
        UnitVolume.deciliters: UnitVolume.cups, UnitVolume.milliliters: UnitVolume.fluidOunces,
        UnitVolume.fluidOunces: UnitVolume.milliliters, UnitVolume.tablespoons: UnitVolume.milliliters,
        UnitVolume.teaspoons: UnitVolume.milliliters, UnitVolume.centiliters: UnitVolume.fluidOunces,
        UnitSpeed.kilometersPerHour: UnitSpeed.milesPerHour, UnitSpeed.milesPerHour: UnitSpeed.kilometersPerHour,
        UnitSpeed.metersPerSecond: UnitSpeed.kilometersPerHour, UnitSpeed.knots: UnitSpeed.kilometersPerHour,
        UnitInformationStorage.gigabytes: UnitInformationStorage.megabytes,
        UnitInformationStorage.megabytes: UnitInformationStorage.kilobytes,
        UnitInformationStorage.terabytes: UnitInformationStorage.gigabytes,
        UnitInformationStorage.kilobytes: UnitInformationStorage.bytes,
        UnitInformationStorage.bytes: UnitInformationStorage.kilobytes,
        UnitDuration.hours: UnitDuration.minutes, UnitDuration.minutes: UnitDuration.seconds,
        UnitDuration.seconds: UnitDuration.minutes,
        UnitArea.squareMeters: UnitArea.squareFeet, UnitArea.squareFeet: UnitArea.squareMeters,
        UnitArea.acres: UnitArea.hectares, UnitArea.hectares: UnitArea.acres,
        UnitArea.squareKilometers: UnitArea.squareMeters,
        UnitEnergy.kilocalories: UnitEnergy.kilojoules, UnitEnergy.kilojoules: UnitEnergy.kilocalories,
        UnitEnergy.kilowattHours: UnitEnergy.kilojoules,
    ]

    /// amount, from, optional to. "$100 to eur", "100 usd in sek", "5km", "100 kr", "20 c to f".
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*([$€£¥₹₩])?\s*(\d[\d\s]*(?:[.,]\d+)?)\s*([^\d\s][^\s]*?)?\s*(?:(?:to|in|i|till|=|->|→)\s+([^\s]+))?\s*$"#,
        options: .caseInsensitive)

    func convert(_ input: String) -> [Result] {
        let text = input.lowercased()
        guard let m = Self.pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
        guard let amountText = group(2)?.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: "."),
              let amount = Double(amountText) else { return [] }
        let fromWord = group(1) ?? group(3)
        guard let fromWord, !fromWord.isEmpty else { return [] }
        let toWord = group(4)

        // Currency (a target unit of mass turns "pounds" into weight).
        if let from = Self.currencyNames[fromWord] ?? (fromWord.count == 3 && rates[fromWord.uppercased()] != nil
                                                        ? fromWord.uppercased() : nil),
           !(fromWord.hasPrefix("pound") && toWord.flatMap({ Self.units[$0] }) is UnitMass) {
            let targets: [String]
            if let toWord {
                guard let to = Self.currencyNames[toWord] ?? (rates[toWord.uppercased()] != nil ? toWord.uppercased() : nil)
                else { return [] }
                targets = [to]
            } else {
                targets = from == home ? ["EUR", "USD"].filter { $0 != home } : [home]
            }
            guard let rFrom = rates[from] else { return [] }
            return targets.compactMap { to in
                guard let rTo = rates[to] else { return nil }
                let value = amount / rFrom * rTo
                let shown = Self.money(value, to)
                return Result(text: "\(Self.money(amount, from)) = \(shown)", result: shown, copy: Self.plain(value),
                              note: "ECB rate from \(ratesDate)")
            }
        }

        // Units.
        let fromKey = fromWord == "pound" || fromWord == "pounds" ? "lb" : fromWord
        guard let fromUnit = Self.units[fromKey] as? Dimension else { return [] }
        let toUnit: Dimension
        if let toWord {
            let key = toWord == "pound" || toWord == "pounds" ? "lb" : toWord
            guard let u = Self.units[key] as? Dimension, type(of: u) == type(of: fromUnit) else { return [] }
            toUnit = u
        } else {
            guard let u = Self.defaultTarget[fromUnit] as? Dimension else { return [] }
            toUnit = u
        }
        let value = Measurement(value: amount, unit: fromUnit).converted(to: toUnit)
        let f = MeasurementFormatter()
        f.unitOptions = .providedUnit
        f.unitStyle = .medium
        f.numberFormatter.maximumFractionDigits = abs(value.value) < 10 ? 3 : 2
        let source = f.string(from: Measurement(value: amount, unit: fromUnit))
        let shown = f.string(from: value)
        return [Result(text: "\(source) = \(shown)", result: shown, copy: Self.plain(value.value), note: "Unit conversion")]
    }

    private static func money(_ value: Double, _ code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.locale = Locale.current
        f.maximumFractionDigits = value < 1 ? 4 : 2
        return f.string(from: NSNumber(value: value)) ?? "\(value) \(code)"
    }

    private static func plain(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 4
        f.locale = Locale.current
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }
}
