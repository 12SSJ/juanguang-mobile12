import SwiftUI

struct ContentView: View {
    @State private var machine = ""
    @State private var tier: LicenseTier = .month1
    @State private var copied = false
    @FocusState private var machineFocused: Bool

    private var code: String? {
        Keygen.generate(machine: machine, index: tier.index)
    }

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    machineSection
                    tierSection
                    resultSection
                    tipSection
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onTapGesture { machineFocused = false }
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.10, green: 0.10, blue: 0.15), Color(red: 0.03, green: 0.03, blue: 0.05)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white, Color(white: 0.85), Color(white: 0.52)],
                        center: .init(x: 0.32, y: 0.3),
                        startRadius: 1,
                        endRadius: 26
                    )
                )
                .frame(width: 38, height: 38)
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text("娟光阅影 · 注册机")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                Text("DEVICE LICENSE GENERATOR")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .tracking(1.4)
            }
            Spacer()
            Text("注册机")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.gold)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.gold.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.bottom, 10)
    }

    private var machineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("机器码")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                TextField("如 FB82-D75D-8667-D4D9", text: $machine)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .keyboardType(.asciiCapable)
                    .focused($machineFocused)
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 13)
                    .background(Theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(machineFocused ? Theme.gold.opacity(0.55) : Color.white.opacity(0.09), lineWidth: 1)
                    )
                Button {
                    if let text = UIPasteboard.general.string {
                        machine = text
                        machineFocused = false
                    }
                } label: {
                    Text("粘贴")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.gold)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                        .background(Theme.gold.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(Theme.gold.opacity(0.35), lineWidth: 1)
                        )
                }
            }
            Text(machineHint)
                .font(.system(size: 11))
                .foregroundStyle(machineHintColor)
        }
        .padding(.top, 8)
    }

    private var machineHint: String {
        if machine.isEmpty { return "把 App 激活页上显示的本机机器码粘贴到这里" }
        if Keygen.normalize(machine).count < 16 { return "机器码不完整，应为 16 位，如 FB82-D75D-8667-D4D9" }
        return "已识别机器码 \(Keygen.normalize(machine))"
    }

    private var machineHintColor: Color {
        if machine.isEmpty { return Theme.muted.opacity(0.7) }
        return Keygen.normalize(machine).count < 16 ? Color(red: 0.94, green: 0.42, blue: 0.42) : Theme.gold.opacity(0.85)
    }

    private var tierSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("授权时段")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Menu {
                Picker("授权时段", selection: $tier) {
                    ForEach(LicenseTier.allCases) { item in
                        Text("\(item.title)（\(item.detail)）").tag(item)
                    }
                }
            } label: {
                HStack {
                    Text(tier.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                    Text(tier.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(Theme.field)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                )
            }
        }
        .padding(.top, 18)
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("注册码")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            VStack(spacing: 12) {
                Text(code ?? (machine.isEmpty ? "等待输入机器码…" : "机器码不完整"))
                    .font(.system(size: code == nil ? 15 : 22, weight: code == nil ? .regular : .semibold, design: .monospaced))
                    .foregroundStyle(code == nil ? Theme.muted.opacity(0.6) : Theme.gold)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .minimumScaleFactor(0.7)
                Button {
                    guard let value = code else { return }
                    UIPasteboard.general.string = value
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        copied = false
                    }
                } label: {
                    Text(copied ? "已复制" : "复制注册码")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.13, green: 0.10, blue: 0.03))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            LinearGradient(
                                colors: [Theme.goldLight, Theme.gold],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .disabled(code == nil)
                .opacity(code == nil ? 0.5 : 1)
            }
            .padding(16)
            .background(Theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.gold.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
        }
        .padding(.top, 18)
    }

    private var tipSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("用法：在 App 激活页抄下「本机机器码」→ 选择授权时段 → 生成并复制注册码 → 回到 App 粘贴激活。")
            Text("注册码与机器码一一对应，换机后需重新生成；时段自用户激活当天起按自然月计算，到期需重新获取。")
            Text("iOS 机器码由机型、处理器、内存、IDFV 与设备种子计算得出，注册码按固定密钥（JGY-2026-MOONLIGHT）生成，请勿修改密钥。")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.muted.opacity(0.65))
        .lineSpacing(3)
        .padding(.top, 20)
    }
}

private enum Theme {
    static let gold = Color(red: 0.91, green: 0.73, blue: 0.36)
    static let goldLight = Color(red: 0.95, green: 0.79, blue: 0.47)
    static let muted = Color(red: 0.56, green: 0.56, blue: 0.62)
    static let field = Color(red: 0.04, green: 0.04, blue: 0.06)
}
