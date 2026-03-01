import SwiftUI

struct TimeRangeDialog: View {
    @EnvironmentObject var viewModel: GalleryViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedPreset: TimeRangePreset = .allTime
    @State private var customStartDate: Date? = nil
    @State private var customEndDate: Date? = nil
    @State private var showingStartDatePicker = false
    @State private var showingEndDatePicker = false
    
    private var displayedFromDate: String {
        if let customStartDate = customStartDate {
            return formatDate(customStartDate)
        } else if case .allTime = selectedPreset {
            return "Select Start Date"
        } else if case .custom = selectedPreset {
            return "Select Start Date"
        } else {
            let dateRange = selectedPreset.dateRange
            if let from = dateRange.from {
                return formatDate(from)
            }
            return "Select Start Date"
        }
    }
    
    private var displayedToDate: String {
        if let customEndDate = customEndDate {
            return formatDate(customEndDate)
        } else if case .allTime = selectedPreset {
            return "Select End Date"
        } else if case .custom = selectedPreset {
            return "Select End Date"
        } else {
            let dateRange = selectedPreset.dateRange
            if let to = dateRange.to {
                return formatDate(to)
            }
            return "Select End Date"
        }
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Title
            Text("Select Time Range")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 24)
            
            // Preset buttons
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    PresetButton(title: "Last Day", isSelected: isPresetSelected(.lastDay)) {
                        selectedPreset = .lastDay
                        customStartDate = nil
                        customEndDate = nil
                    }
                    PresetButton(title: "Last Week", isSelected: isPresetSelected(.lastWeek)) {
                        selectedPreset = .lastWeek
                        customStartDate = nil
                        customEndDate = nil
                    }
                    PresetButton(title: "Last Month", isSelected: isPresetSelected(.lastMonth)) {
                        selectedPreset = .lastMonth
                        customStartDate = nil
                        customEndDate = nil
                    }
                }
                
                HStack(spacing: 12) {
                    PresetButton(title: "Last Year", isSelected: isPresetSelected(.lastYear)) {
                        selectedPreset = .lastYear
                        customStartDate = nil
                        customEndDate = nil
                    }
                    PresetButton(title: "All Time", isSelected: isPresetSelected(.allTime)) {
                        selectedPreset = .allTime
                        customStartDate = nil
                        customEndDate = nil
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            
            // Custom date range
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    Text("From:")
                        .font(.body)
                        .frame(width: 50, alignment: .leading)
                    
                    Button(action: {
                        showingStartDatePicker = true
                        // When selecting custom dates, switch to custom preset
                        if case .allTime = selectedPreset {
                            // Don't auto-switch from All Time
                        } else if customStartDate != nil || customEndDate != nil {
                            selectedPreset = .custom(from: customStartDate, to: customEndDate)
                        }
                    }) {
                        Text(displayedFromDate)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
                
                HStack(spacing: 16) {
                    Text("To:")
                        .font(.body)
                        .frame(width: 50, alignment: .leading)
                    
                    Button(action: {
                        showingEndDatePicker = true
                        // When selecting custom dates, switch to custom preset
                        if case .allTime = selectedPreset {
                            // Don't auto-switch from All Time
                        } else if customStartDate != nil || customEndDate != nil {
                            selectedPreset = .custom(from: customStartDate, to: customEndDate)
                        }
                    }) {
                        Text(displayedToDate)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 40) {
                Button("Cancel") {
                    dismiss()
                }
                .font(.body)
                .foregroundColor(.blue)
                
                Button("Apply") {
                    applyTimeRange()
                    dismiss()
                }
                .font(.body)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.blue)
                .cornerRadius(8)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: 350, maxHeight: 400)
        .background(Color(.systemBackground))
        .cornerRadius(20)
        .shadow(radius: 20)
        .sheet(isPresented: $showingStartDatePicker) {
            DatePickerSheet(
                selectedDate: Binding(
                    get: { customStartDate ?? Date() },
                    set: { customStartDate = $0 }
                ),
                title: "Select Start Date"
            )
        }
        .sheet(isPresented: $showingEndDatePicker) {
            DatePickerSheet(
                selectedDate: Binding(
                    get: { customEndDate ?? Date() },
                    set: { customEndDate = $0 }
                ),
                title: "Select End Date"
            )
        }
        .onAppear {
            // Initialize with current selection
            selectedPreset = viewModel.selectedTimeRange
            if case .custom(let from, let to) = selectedPreset {
                customStartDate = from
                customEndDate = to
            }
        }
    }
    
    private func isPresetSelected(_ preset: TimeRangePreset) -> Bool {
        switch (selectedPreset, preset) {
        case (.lastDay, .lastDay),
             (.lastWeek, .lastWeek),
             (.lastMonth, .lastMonth),
             (.lastYear, .lastYear),
             (.allTime, .allTime):
            return true
        default:
            return false
        }
    }
    
    private func applyTimeRange() {
        // Check if custom dates were selected
        if customStartDate != nil || customEndDate != nil {
            viewModel.selectedTimeRange = .custom(from: customStartDate, to: customEndDate)
        } else {
            viewModel.selectedTimeRange = selectedPreset
        }
        
        // Enable time range filter if not already
        if viewModel.selectedFilter != .timeRange {
            viewModel.selectedFilter = .timeRange
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

struct PresetButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(isSelected ? .blue : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isSelected ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
                )
        }
    }
}

struct DatePickerSheet: View {
    @Binding var selectedDate: Date
    let title: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                DatePicker(
                    "Select date",
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(GraphicalDatePickerStyle())
                .padding()
                
                Spacer()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("OK") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    TimeRangeDialog()
        .environmentObject(GalleryViewModel())
}