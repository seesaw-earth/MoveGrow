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
                    Button {playback.play(start:start,end:end)} label:{Label("Preview \(clock(start))–\(clock(end))",systemImage:"play.circle")}
                }
                Section("Choose a clip") {
                    HStack {Text("Start");Spacer();Text(String(format:"%.1f s",start)).monospacedDigit()}
                    Slider(value:$start,in:0...max(0.1,memory.duration),step:0.1).accessibilityLabel("Clip start time")
                    HStack {Text("End");Spacer();Text(String(format:"%.1f s",end)).monospacedDigit()}
                    Slider(value:$end,in:0...max(0.1,memory.duration),step:0.1).accessibilityLabel("Clip end time")
                    if end <= start {Text("End time must be after start time.").foregroundStyle(.red)}
                }
                Section {
                    TextField("Give this moment a name",text:$title)
                    Menu("Ideas") {
                        ForEach(["First smile","Reaching for a toy","Rolling over","Little kicks","A new move"],id:\.self) { idea in Button(idea){title = idea} }
                    }
                    DatePicker("First noticed",selection:$date,in:(store.album.baby?.birthday ?? .distantPast)...Date(),displayedComponents:.date)
                    TextField("Add a note (optional)",text:$note,axis:.vertical)
                } header: {
                    Text("Your milestone")
                } footer: {
                    Text("You choose what this moment means. Saving a milestone does not confirm a developmental skill.")
                }
            }.navigationTitle("Save milestone").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}.disabled(saving)}
                    ToolbarItem(placement:.confirmationAction){Button("Save"){
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
    @State private var grouping = "Months"
    @State private var selectMemory = false
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
                Text("Every point leads to a little moment.").font(.subheadline).foregroundStyle(.secondary)

                if !pendingSuggestions.isEmpty { suggestionsSection }

                Picker("Timeline grouping",selection:$grouping){Text("Days").tag("Days");Text("Months").tag("Months")}.pickerStyle(.segmented)
                if moments.isEmpty && pendingSuggestions.isEmpty {
                    ContentUnavailableView("Connect your first milestone",systemImage:"bookmark",description:Text("Choose a few seconds from a memory. Give it a name and add it here."))
                    Button("Choose a memory"){selectMemory = true}.buttonStyle(.borderedProminent).disabled(store.album.memories.isEmpty)
                }
                ForEach(groups,id:\.self){date in
                    Text(date.formatted(grouping == "Days" ? .dateTime.month(.wide).day().year() : .dateTime.month(.wide).year())).font(.headline)
                    VStack(spacing:0){
                        ForEach(moments.filter {bucket($0.date) == date}){moment in
                            if let memory = store.memory(moment.memoryID){
                                HStack(spacing:12){
                                    VStack(spacing:0){
                                        Rectangle().fill(Color.teal.opacity(0.25)).frame(width:2,height:12)
                                        NavigationLink {
                                            MemoryDetailView(memoryID:memory.id,initialStart:moment.start,initialEnd:moment.end)
                                        } label: {
                                            Circle().fill(.teal).frame(width:10,height:10).frame(width:44,height:44).contentShape(Rectangle())
                                        }.buttonStyle(.plain).accessibilityLabel("Play milestone: \(moment.title)")
                                        Rectangle().fill(Color.teal.opacity(0.25)).frame(width:2)
                                    }.frame(width:44)
                                    NavigationLink {
                                        MemoryDetailView(memoryID:memory.id,initialStart:moment.start,initialEnd:moment.end)
                                    }label:{
                                        HStack(spacing:12){
                                            Thumbnail(filename:moment.thumbnail ?? memory.thumbnail).frame(width:64,height:64).clipShape(RoundedRectangle(cornerRadius:10))
                                                .overlay {Image(systemName:"play.fill").font(.caption).foregroundStyle(.white).padding(6).background(.black.opacity(0.45)).clipShape(Circle())}
                                            VStack(alignment:.leading,spacing:4){
                                                Text(moment.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                                Text(moment.date.formatted(date:.abbreviated,time:.omitted)).font(.caption).foregroundStyle(.secondary)
                                                if let baby = store.album.baby {Text("\(baby.age(on:moment.date)) · \(clock(moment.end-moment.start)) clip").font(.caption).foregroundStyle(.secondary)}
                                                if !moment.note.isEmpty {Text(moment.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)}
                                            }
                                            Spacer(minLength:0)
                                        }.padding(.vertical,10).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("Play \(moment.title), \(moment.date.formatted(date:.abbreviated,time:.omitted))")
                                        .contextMenu {Button("Remove milestone",systemImage:"bookmark.slash",role:.destructive){deleteTarget = moment}}
                                }.fixedSize(horizontal:false,vertical:true)
                            }
                        }
                    }
                }
                Link("Explore age-based milestones · CDC",destination:URL(string:"https://www.cdc.gov/act-early/milestones/")!).font(.footnote).padding(.top)
                Text("Your timeline records what you noticed. It is not a developmental checklist or score.").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }.navigationTitle("Growth")
            .toolbar {Button {selectMemory = true}label:{Label("Add milestone",systemImage:"plus")}.disabled(store.album.memories.isEmpty)}
            .sheet(isPresented:$selectMemory){MemoryChooser()}
            .confirmationDialog("Remove this milestone? The video will stay in Memories.",isPresented:Binding(get:{deleteTarget != nil},set:{if !$0{deleteTarget = nil}}),titleVisibility:.visible){
                Button("Remove milestone",role:.destructive){
                    if let target = deleteTarget {do{try store.deleteMoment(target.id)}catch{store.error = error.localizedDescription}}
                    deleteTarget = nil
                }
            }
    }

    @ViewBuilder private var suggestionsSection: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label("Suggestions to review",systemImage:"sparkles").font(.headline)
                Spacer()
                Text("\(pendingSuggestions.count)").font(.caption.weight(.semibold)).padding(.horizontal,8).padding(.vertical,4).background(.teal.opacity(0.12)).clipShape(Capsule())
            }
            Text("MoveGrow noticed these movement patterns on-device. Watch the clip before adding one to your timeline.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(pendingSuggestions) { item in
                VStack(alignment:.leading,spacing:10) {
                    NavigationLink {
                        MemoryDetailView(memoryID:item.memory.id,initialStart:item.suggestion.start,initialEnd:item.suggestion.end)
                    } label: {
                        HStack(spacing:12) {
                            Thumbnail(filename:item.memory.thumbnail).frame(width:58,height:58).clipShape(RoundedRectangle(cornerRadius:10))
                                .overlay { Image(systemName:"play.fill").font(.caption).foregroundStyle(.white).padding(6).background(.black.opacity(0.45)).clipShape(Circle()) }
                            VStack(alignment:.leading,spacing:3) {
                                Text(item.suggestion.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text("\(clock(item.suggestion.start))–\(clock(item.suggestion.end)) · \(matchLabel(item.suggestion.score))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(item.memory.date.formatted(date:.abbreviated,time:.omitted)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)
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
                            else { Label("Add to timeline",systemImage:"bookmark.fill") }
                        }.buttonStyle(.borderedProminent).disabled(workingSuggestion != nil)

                        Button("Not this movement") {
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
        .background(.teal.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius:18))
    }

    private func matchLabel(_ score: Double) -> String {
        score >= 0.84 ? "strong pattern match" : "possible pattern match"
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
                    HStack {Thumbnail(filename:m.thumbnail).frame(width:56,height:56).clipShape(RoundedRectangle(cornerRadius:8));VStack(alignment:.leading){Text(m.title);Text(m.date.formatted(date:.abbreviated,time:.omitted)).font(.caption).foregroundStyle(.secondary)}}
                }.buttonStyle(.plain)
            }.navigationTitle("Choose a memory").toolbar {Button("Done"){dismiss()}}
                .sheet(item:$selected){m in MomentEditor(memory:m,seed:ClipSeed(start:0,end:min(5,m.duration),title:""))}
        }
    }
}
