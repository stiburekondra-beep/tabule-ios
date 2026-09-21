import SwiftUI
import UIKit

/// Rolovací sekce s diagnostickým logem (`Core/Log.swift`) — dole na
/// hlavní i nouzové obrazovce (Ondrova připomínka z F18: „proč tam nemáš
/// nějaký log, ať to vidíš"). Monospace, malé písmo, nejnovější dole,
/// auto-scroll. Tlačítka Kopírovat a Odeslat na server (i bez nastaveného
/// log serveru je vidět aspoň lokálně v appce).
///
/// Sbalená ukazuje jen záhlaví s počtem záznamů, ať nezabírá místo, když
/// se neladí — na hlavní obrazovce (nad WKWebView cockpitem) to je
/// důležité, aby log nepřekrýval cockpit, dokud ho Ondra nerozbalí.
struct LogView: View {
    @ObservedObject private var log = Log.sdilene
    @State private var rozbaleno = false
    @State private var zkopirovano = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            zahlavi
            if rozbaleno {
                seznam
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: rozbaleno ? 12 : 8))
    }

    private var zahlavi: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { rozbaleno.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: rozbaleno ? "chevron.down" : "chevron.up")
                    .font(.caption)
                Text(rozbaleno ? "Log (\(log.zaznamy.count))" : "Log")
                    .font(.footnote).bold()
                Spacer()
                if rozbaleno && !log.zaznamy.isEmpty {
                    Button(zkopirovano ? "Zkopírováno" : "Kopírovat") { kopirovat() }
                        .font(.caption)
                    Button("Odeslat na server") { Task { await LogUploader.sdileny.odeslatIhned() } }
                        .font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var seznam: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if log.zaznamy.isEmpty {
                        Text("zatím nic").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(log.zaznamy) { zaznam in
                        Text(zaznam.zformatovano)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(barva(zaznam.uroven))
                            .id(zaznam.id)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            .frame(height: 200)
            .onChange(of: log.zaznamy.count) { _ in
                guard let posledni = log.zaznamy.last else { return }
                withAnimation { proxy.scrollTo(posledni.id, anchor: .bottom) }
            }
            .onAppear {
                guard let posledni = log.zaznamy.last else { return }
                proxy.scrollTo(posledni.id, anchor: .bottom)
            }
        }
    }

    private func kopirovat() {
        UIPasteboard.general.string = log.jakoText
        zkopirovano = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            zkopirovano = false
        }
    }

    private func barva(_ uroven: Log.Uroven) -> Color {
        switch uroven {
        case .info: return .primary
        case .odeslano: return .cyan
        case .prijato: return .green
        case .chyba: return .red
        }
    }
}
