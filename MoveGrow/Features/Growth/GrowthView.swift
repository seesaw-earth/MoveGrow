// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import AVKit

struct ClipSeed: Identifiable {
    let id = UUID()
    var start:Double
    var end:Double
    var title:String
}

struct MomentEditor: View {
    @EnvironmentObject private var store:LocalStore
    @Environment(\.dismiss) private var dismiss
    let memory:Memory
    @State private var title:String
    @State private var start:Double
    @State private var end:Double
    @State private var date:Date
    @State private var note = ""
    @State private var saving = false
    @StateObject private var playback:ClipPlayer
    init(memory:Memory,seed:ClipSeed) {
        self.memory = memory
        _title = State(initialValue:seed.title)
        let lo = min(max(0,seed.start),max(0,memory.duration-0.1))
        _start = State(initialValue:lo)
        _end = State(initialValue:min(memory.duration,max(lo+0.1,seed.end)))
        _date = State(initialValue:memory.date)
        _playback = StateObject(wrappedValue:ClipPlayer(url:LocalFiles.url(memory.filename)))
    }
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    VideoPlayer(player:playback.player).frame(height:210)
                    Button(tr("Play %1$@–%2$@", clock(start), clock(end))) {playback.play(start:start,end:end)}
                }
                Section(tr("Choose a clip")) {
                    HStack {Text(tr("Start"));Spacer();Text(tr("%@ s", L10n.number(start, digits: 1))).monospacedDigit()}
                    Slider(value:$start,in:0...max(0.1,memory.duration),step:0.1).accessibilityLabel(tr("Clip start time"))
                    HStack {Text(tr("End"));Spacer();Text(tr("%@ s", L10n.number(end, digits: 1))).monospacedDigit()}
                    Slider(value:$end,in:0...max(0.1,memory.duration),step:0.1).accessibilityLabel(tr("Clip end time"))
                    if end <= start {Text(tr("The end must be after the start.")).foregroundStyle(.red)}
                }
                Section {
                    TextField(tr("Give this moment a name"),text:$title)
                    Menu(tr("Ideas")) {
                        ForEach([tr("First smile"),tr("Reaching for a toy"),tr("Rolling over"),tr("Little kicks"),tr("A new move")],id:\.self) { idea in Button(idea){title = idea} }
                    }
                    DatePicker(tr("First noticed"),selection:$date,in:(store.album.baby?.birthday ?? .distantPast)...Date(),displayedComponents:.date)
                    TextField(tr("Add a note (optional)"),text:$note,axis:.vertical)
                } header: {
                    Text(tr("Your milestone"))
                } footer: {
                    Text(tr("You choose what this moment means. Saving a milestone does not confirm a developmental skill."))
                }
            }.navigationTitle(tr("Save milestone")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction){Button(tr("Cancel")){dismiss()}.disabled(saving)}
                    ToolbarItem(placement:.confirmationAction){Button(tr("Save")){
                        saving = true
                        Task {
                            do {
                                try await store.addMoment(Moment(memoryID:memory.id,title:title.trimmingCharacters(in:.whitespacesAndNewlines),date:date,start:start,end:end,note:note))
                                dismiss()
                            }catch{store.error = error.localizedDescription}
                            saving = false
                        }
                    }.disabled(saving || title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || end <= start || end > memory.duration)}
                }
                .interactiveDismissDisabled(saving)
                .onDisappear {playback.stop()}
        }
    }
}

private struct PendingMilestoneSuggestion: Identifiable {
    let memory: Memory
    let suggestion: MilestoneSuggestion
    var id: UUID { suggestion.id }
}

struct GrowthView:View {
    @EnvironmentObject private var store:LocalStore
    @AppStorage("growthGrouping") private var grouping = "Months"
    @State private var selectMemory = false
    @State private var exporting = false
    // The trend chart's choices, shared with the PNG export (kept across language changes).
    @AppStorage("trendMetric") private var metric: TrendMetric = .activity
    @AppStorage("trendByDay") private var byDay = false
    @AppStorage("trendByAge") private var byAge = false
    @State private var deleteTarget:Moment?
    @State private var workingSuggestion: UUID?

    private var moments:[Moment] {store.album.moments.sorted {$0.date > $1.date}}
    private var pendingSuggestions:[PendingMilestoneSuggestion] {
        store.album.memories
            .flatMap { memory in
                (memory.milestoneSuggestions ?? [])
                    .filter { $0.status == .suggested }
                    .map { PendingMilestoneSuggestion(memory: memory, suggestion: $0) }
            }
            .sorted {
                if $0.memory.date == $1.memory.date { return $0.suggestion.score > $1.suggestion.score }
                return $0.memory.date > $1.memory.date
            }
    }
    private func bucket(_ date:Date)->Date {
        Calendar.current.dateInterval(of:grouping == "Days" ? .day : .month,for:date)?.start ?? date
    }
    private var groups:[Date] {Array(Set(moments.map {bucket($0.date)})).sorted(by:>)}

    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                KinematicTrendsSection(metric: $metric, byDay: $byDay, byAge: $byAge)
                if !pendingSuggestions.isEmpty { suggestionsSection }
                MotorTrendsSection()

                Text(tr("Milestones")).font(.mgSection).foregroundStyle(Color.mgInk).padding(.top, 4)
                Picker(tr("Timeline grouping"),selection:$grouping){Text(tr("Days")).tag("Days");Text(tr("Months")).tag("Months")}.pickerStyle(.segmented)
                if moments.isEmpty && pendingSuggestions.isEmpty {
                    ContentUnavailableView(tr("Add your first milestone"),systemImage:"bookmark",description:Text(tr("Choose a few seconds from a memory. Give it a name and add it here.")))
                    Button(tr("Choose a memory")){selectMemory = true}.buttonStyle(.borderedProminent).disabled(store.album.memories.isEmpty)
                }
                ForEach(groups,id:\.self){date in
                    Text(grouping == "Days" ? L10n.date(date, .long) : L10n.monthYear(date)).font(.headline)
                    VStack(spacing:0){
                        ForEach(moments.filter {bucket($0.date) == date}){moment in
                            if let memory = store.memory(moment.memoryID){
                                HStack(spacing:12){
                                    VStack(spacing:0){
                                        Rectangle().fill(Color.mgSage.opacity(0.25)).frame(width:2,height:12)
                                        NavigationLink {
                                            MemoryDetailView(memoryID:memory.id,initialStart:moment.start,initialEnd:moment.end)
                                        } label: {
                                            Circle().fill(Color.mgSage).frame(width:10,height:10).frame(width:44,height:44).contentShape(Rectangle())
                                        }.buttonStyle(.plain).accessibilityLabel(tr("Play milestone: %@", moment.title))
                                        Rectangle().fill(Color.mgSage.opacity(0.25)).frame(width:2)
                                    }.frame(width:44)
                                    NavigationLink {
                                        MemoryDetailView(memoryID:memory.id,initialStart:moment.start,initialEnd:moment.end)
                                    }label:{
                                        HStack(spacing:12){
                                            Thumbnail(filename:moment.thumbnail ?? memory.thumbnail).frame(width:64,height:64).clipShape(RoundedRectangle(cornerRadius:10))
                                            VStack(alignment:.leading,spacing:4){
                                                Text(moment.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                                Text(L10n.date(moment.date)).font(.caption).foregroundStyle(.secondary)
                                                if let baby = store.album.baby {Text(tr("%1$@ · %2$@ clip", baby.age(on:moment.date), clock(moment.end-moment.start))).font(.caption).foregroundStyle(.secondary)}
                                                if !moment.note.isEmpty {Text(moment.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)}
                                            }
                                            Spacer(minLength:0)
                                        }.padding(.vertical,10).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel(tr("Play %1$@, %2$@", moment.title, L10n.date(moment.date)))
                                        .contextMenu {Button(tr("Remove milestone"),role:.destructive){deleteTarget = moment}}
                                }.fixedSize(horizontal:false,vertical:true)
                            }
                        }
                    }
                }
                Link(tr("Age-based milestones (CDC)"),destination:URL(string:"https://www.cdc.gov/act-early/milestones/")!).font(.footnote).padding(.top)
                Text(tr("Your timeline records what you noticed. It is not a developmental checklist or score.")).font(.caption).foregroundStyle(.secondary)
            }.padding()
        }.navigationTitle(tr("Growth"))
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Button {exporting = true} label:{Image(systemName:"square.and.arrow.up")}
                        .accessibilityLabel(tr("Export charts as an image"))
                        .disabled(!store.album.memories.contains { $0.kinematics != nil })
                }
                ToolbarItem(placement:.topBarTrailing) {
                    Button {selectMemory = true} label:{Image(systemName:"plus")}
                        .accessibilityLabel(tr("Add milestone"))
                        .disabled(store.album.memories.isEmpty)
                }
            }
            .sheet(isPresented:$selectMemory){MemoryChooser()}
            .sheet(isPresented:$exporting){GrowthExportSheet(metric:metric, byDay:byDay, byAge:byAge)}
            .confirmationDialog(tr("Remove this milestone? The video will stay in Memories."),isPresented:Binding(get:{deleteTarget != nil},set:{if !$0{deleteTarget = nil}}),titleVisibility:.visible){
                Button(tr("Remove milestone"),role:.destructive){
                    if let target = deleteTarget {do{try store.deleteMoment(target.id)}catch{store.error = error.localizedDescription}}
                    deleteTarget = nil
                }
            }
    }

    @ViewBuilder private var suggestionsSection: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(tr("Suggestions to review")).font(.headline)
                Spacer()
                Text(verbatim: "\(pendingSuggestions.count)").font(.caption.weight(.semibold)).padding(.horizontal,8).padding(.vertical,4).background(Color.mgSage.opacity(0.12)).clipShape(Capsule())
            }
            Text(tr("MoveGrow noticed these movement patterns on this iPhone. Watch the clip before adding one to your timeline."))
                .font(.caption).foregroundStyle(.secondary)

            ForEach(pendingSuggestions) { item in
                VStack(alignment:.leading,spacing:10) {
                    NavigationLink {
                        MemoryDetailView(memoryID:item.memory.id,initialStart:item.suggestion.start,initialEnd:item.suggestion.end)
                    } label: {
                        HStack(spacing:12) {
                            Thumbnail(filename:item.memory.thumbnail).frame(width:58,height:58).clipShape(RoundedRectangle(cornerRadius:10))
                            VStack(alignment:.leading,spacing:3) {
                                Text(item.suggestion.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(tr("%1$@–%2$@ · %3$@", clock(item.suggestion.start), clock(item.suggestion.end), matchLabel(item.suggestion.score)))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(item.memory.dateText).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }.buttonStyle(.plain)

                    HStack {
                        Button {
                            workingSuggestion = item.id
                            Task {
                                do { try await store.confirmSuggestion(memoryID:item.memory.id,suggestionID:item.id) }
                                catch { store.error = error.localizedDescription }
                                workingSuggestion = nil
                            }
                        } label: {
                            if workingSuggestion == item.id { ProgressView().controlSize(.small) }
                            else { Text(tr("Add to timeline")) }
                        }.buttonStyle(.borderedProminent).disabled(workingSuggestion != nil)

                        Button(tr("Not this movement")) {
                            do { try store.dismissSuggestion(memoryID:item.memory.id,suggestionID:item.id) }
                            catch { store.error = error.localizedDescription }
                        }.buttonStyle(.bordered).disabled(workingSuggestion != nil)
                    }.font(.caption)
                }
                .padding(12)
                .background(.background.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius:14))
            }
        }
        .padding(14)
        .background(Color.mgSage.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius:18))
    }

    private func matchLabel(_ score: Double) -> String {
        score >= 0.84 ? tr("strong match") : tr("possible match")
    }
}

private struct MemoryChooser:View {
    @EnvironmentObject private var store:LocalStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected:Memory?
    var body:some View {
        NavigationStack {
            List(store.album.memories.sorted {$0.date > $1.date}){m in
                Button {selected = m}label:{
                    HStack {Thumbnail(filename:m.thumbnail).frame(width:56,height:56).clipShape(RoundedRectangle(cornerRadius:8));VStack(alignment:.leading){Text(m.displayTitle);Text(m.dateText).font(.caption).foregroundStyle(.secondary)}}
                }.buttonStyle(.plain)
            }.navigationTitle(tr("Choose a memory")).toolbar {Button(tr("Done")){dismiss()}}
                .sheet(item:$selected){m in MomentEditor(memory:m,seed:ClipSeed(start:0,end:min(5,m.duration),title:""))}
        }
    }
}

/// Observations that recur across recordings (one video is never enough to call a pattern).
private struct MotorTrendsSection: View {
    @EnvironmentObject private var store: LocalStore
    var body: some View {
        let trends = store.motorTrends().filter { $0.detectedSessions > 0 }
            .sorted { ($0.persistent ? 1 : 0, $0.severity, $0.detectedSessions) > ($1.persistent ? 1 : 0, $1.severity, $1.detectedSessions) }
        if !trends.isEmpty {
            VStack(alignment:.leading, spacing:10) {
                Text(tr("Across recordings")).font(.headline)
                ForEach(trends) { t in
                    VStack(alignment:.leading, spacing:3) {
                        HStack {
                            Text(t.name.text).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(tr("%1$lld of %2$lld", t.detectedSessions, t.evaluatedSessions)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if t.persistent {
                            Text(t.severity >= .discuss ? tr("Seen repeatedly. Worth mentioning at your next check-up.") : tr("Seen repeatedly."))
                                .font(.caption.weight(.semibold)).foregroundStyle(t.severity >= .discuss ? Color.orange : Color.mgSage)
                        }
                        if let message = t.message?.text, !message.isEmpty {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        } else if let days = t.spanDays, t.detectedSessions > 1 {
                            Text(days == 1 ? tr("Over 1 day.") : tr("Over %lld days.", days)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth:.infinity, alignment:.leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius:12))
                }
                Text(tr("Counts recordings where a check could run. Patterns need several videos on different days."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
