import AIMApplication
import Charts
import SwiftUI

/// OpenRouter's hosts for a model: price, cache, context, output, quantization, uptime.
struct ModelHostsSection: View {
    let endpoints: [OpenRouterEndpoint]
    let loading: Bool
    let available: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Providers").font(.system(size: 15, weight: .semibold))
            Text("Companies that host this model on OpenRouter. OpenRouter routes each request to the best available one.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
            if !available {
                SettingsNotice("This model is not listed on OpenRouter, so host details are not published.")
            } else if loading && endpoints.isEmpty {
                ProgressView().controlSize(.small).padding(.vertical, 20)
            } else if endpoints.isEmpty {
                SettingsNotice("OpenRouter did not return hosts for this model right now.", tone: .warning)
            } else {
                VStack(spacing: 0) {
                    row(header: true, cells: ["Provider", "Input", "Output", "Cache", "Context", "Uptime"])
                    ForEach(endpoints) { endpoint in
                        Rectangle().fill(AIMTheme.rowDivider(scheme)).frame(height: 1)
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(endpoint.providerName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                if let quantization = endpoint.quantization, quantization != "unknown" {
                                    Text(quantization.uppercased()).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            cell(endpoint.pricing?.inputPerMillion.map(ModelFacts.price))
                            cell(endpoint.pricing?.outputPerMillion.map(ModelFacts.price))
                            cell(endpoint.pricing?.cacheReadPerMillion.map(ModelFacts.price))
                            cell(endpoint.contextLength.map(ModelFacts.tokens))
                            UptimeValue(value: endpoint.uptime1d ?? endpoint.uptime30m).frame(width: 96, alignment: .trailing)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 44)
                    }
                }
                .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
                Text("Prices per million tokens. Uptime over the last 24 hours.").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
    }

    private func row(header: Bool, cells: [String]) -> some View {
        HStack(spacing: 0) {
            Text(cells[0]).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(cells.dropFirst().dropLast(), id: \.self) { Text($0).frame(width: 74, alignment: .trailing) }
            Text(cells.last ?? "").frame(width: 96, alignment: .trailing)
        }
        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 34)
    }

    private func cell(_ text: String?) -> some View {
        Text(text ?? "—").font(.system(size: 13)).monospacedDigit().frame(width: 74, alignment: .trailing)
    }
}

/// A percentage with a small green/orange/red bar.
struct UptimeValue: View {
    let value: Double?

    var body: some View {
        HStack(spacing: 6) {
            if let value {
                Capsule().fill(color(value)).frame(width: 18, height: 6)
                Text(value.formatted(.number.precision(.fractionLength(value >= 99.95 ? 0 : 2))) + "%")
                    .font(.system(size: 13)).monospacedDigit()
            } else {
                Text("—").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ value: Double) -> Color { value >= 99 ? .green : value >= 95 ? .orange : .red }
}

/// Current uptime, then the history AIM records (hourly, while it runs).
struct ModelUptimeSection: View {
    let endpoints: [OpenRouterEndpoint]
    let history: [ModelStatsStore.UptimeSample]
    let available: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uptime").font(.system(size: 15, weight: .semibold))
            Text("The share of requests that hosts answered successfully.").font(.system(size: 12.5)).foregroundStyle(.secondary)
            if !available {
                SettingsNotice("This model is not listed on OpenRouter, so uptime is not published.")
            } else {
                HStack(spacing: 10) {
                    figure("Last 5 minutes", best(\.uptime5m))
                    figure("Last 30 minutes", best(\.uptime30m))
                    figure("Last 24 hours", best(\.uptime1d))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("History recorded by AIM").font(.system(size: 13, weight: .semibold))
                    if Set(history.map(\.date)).count < 2 {
                        SettingsNotice("AIM records uptime about once an hour when you look at or use this model; the curve fills in over the next hours and days.")
                    } else {
                        Chart(history, id: \.date) { sample in
                            LineMark(x: .value("Time", sample.date), y: .value("Uptime", sample.uptime))
                                .foregroundStyle(by: .value("Host", sample.host))
                                .interpolationMethod(.monotone)
                        }
                        .chartYScale(domain: max(80, (history.map(\.uptime).min() ?? 90) - 2)...100.5)
                        .chartYAxis { AxisMarks { AxisGridLine(); AxisValueLabel(format: FloatingPointFormatStyle<Double>().precision(.fractionLength(0))) } }
                        .frame(height: 220)
                        .padding(14)
                        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
                    }
                }
            }
        }
    }

    private func best(_ key: KeyPath<OpenRouterEndpoint, Double?>) -> Double? {
        endpoints.compactMap { $0[keyPath: key] }.max()
    }

    private func figure(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).kerning(0.3)
            Text(value.map { $0.formatted(.number.precision(.fractionLength(2))) + "%" } ?? "—")
                .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                .foregroundStyle(value.map { $0 >= 99 ? Color.green : $0 >= 95 ? .orange : .red } ?? .secondary)
            Text("best host").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }
}

/// Speed measured on AIM's own requests to this model (on this Mac for local models:
/// prompt processing too, per engine).
struct ModelSpeedSection: View {
    let samples: [ModelStatsStore.SpeedSample]
    var local = false
    @Environment(\.colorScheme) private var scheme

    private var promptSpeeds: [(Date, Double)] { samples.compactMap { sample in sample.promptTokensPerSecond.map { (sample.date, $0) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(local ? "Performance on this Mac" : "Performance").font(.system(size: 15, weight: .semibold))
            Text(local ? "Measured by AIM each time this model answers on your Mac: reading your prompt, time until the first words, then writing speed."
                       : "Measured by AIM on your own requests: time until the first words, then generation speed.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
            if samples.isEmpty {
                SettingsNotice("No measurement yet. Use this model in a chat and AIM will chart its speed here.")
            } else {
                HStack(spacing: 10) {
                    figure("First words", median(samples.map(\.firstTokenSeconds)).map { $0.formatted(.number.precision(.fractionLength(2))) + " s" })
                    if local, !promptSpeeds.isEmpty {
                        figure("Prompt", median(promptSpeeds.map(\.1)).map { "\(Int($0)) tok/s" })
                    }
                    figure(local ? "Generation" : "Speed", median(samples.map(\.tokensPerSecond)).map { $0.formatted(.number.precision(.fractionLength(1))) + " tok/s" })
                    figure("Measurements", "\(samples.count)")
                }
                if local, Set(samples.compactMap(\.engine)).count > 1 {
                    engineComparison
                }
                HStack(spacing: 10) {
                    chart("Time to first words (s)", samples.map { ($0.date, $0.firstTokenSeconds) }, color: .orange)
                    chart(local ? "Generation (tok/s)" : "Throughput (tok/s)", samples.map { ($0.date, $0.tokensPerSecond) }, color: AIMTheme.toggleOn)
                }
                if local, promptSpeeds.count > 1 {
                    chart("Prompt processing (tok/s)", promptSpeeds, color: .purple)
                }
            }
        }
    }

    /// MLX and llama.cpp side by side when both ran this model.
    private var engineComparison: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By engine").font(.system(size: 13, weight: .semibold))
            SettingsCard {
                ForEach(Array(Set(samples.compactMap(\.engine))).sorted(), id: \.self) { engine in
                    let runs = samples.filter { $0.engine == engine }
                    SettingsRow(engine == "mlx" ? "MLX" : engine, description: "\(runs.count) answers") {
                        Text([median(runs.map(\.tokensPerSecond)).map { $0.formatted(.number.precision(.fractionLength(1))) + " tok/s" },
                              median(runs.map(\.firstTokenSeconds)).map { "first words " + $0.formatted(.number.precision(.fractionLength(2))) + " s" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func figure(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).kerning(0.3)
            Text(value ?? "—").font(.system(size: 18, weight: .semibold)).monospacedDigit()
            Text("median").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }

    private func chart(_ title: String, _ points: [(Date, Double)], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Chart(points, id: \.0) { point in
                LineMark(x: .value("Time", point.0), y: .value(title, point.1)).foregroundStyle(color).interpolationMethod(.monotone)
                PointMark(x: .value("Time", point.0), y: .value(title, point.1)).foregroundStyle(color).symbolSize(18)
            }
            .frame(height: 170)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }
}
