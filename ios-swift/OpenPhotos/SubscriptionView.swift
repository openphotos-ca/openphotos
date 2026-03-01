import SwiftUI
import StoreKit

struct SubscriptionView: View {
    @StateObject private var viewModel = SubscriptionViewModel()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 16) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue.gradient)
                        
                        Text("OpenPhotos Pro")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Unlock unlimited photo organization and advanced features")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top)
                    
                    // Features
                    VStack(spacing: 16) {
                        FeatureRow(
                            icon: "infinity",
                            title: "Unlimited Photos",
                            description: "Organize and clean up your entire photo library"
                        )
                        
                        FeatureRow(
                            icon: "brain.head.profile",
                            title: "AI-Powered Detection",
                            description: "Advanced duplicate detection and smart organization"
                        )
                        
                        FeatureRow(
                            icon: "icloud.and.arrow.up",
                            title: "Cloud Sync",
                            description: "Sync your organization across all devices"
                        )
                        
                        FeatureRow(
                            icon: "photo.stack",
                            title: "Event Organization",
                            description: "Create and share photo events with friends"
                        )
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // Subscription Status
                    VStack(spacing: 12) {
                        if viewModel.isLoading {
                            ProgressView("Loading subscription options...")
                                .frame(height: 100)
                        } else {
                            Text("Subscription products will be available when configured in App Store Connect")
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                    
                    // Demo Purchase Button
                    Button(action: {
                        // Demo functionality
                        print("Demo subscription purchase")
                    }) {
                        HStack {
                            Text("Start Free Trial")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                    }
                    
                    // Trial Info
                    Text("3-day free trial, then $4.99/month")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    // Footer
                    VStack(spacing: 8) {
                        HStack(spacing: 20) {
                            Button("Terms of Service") {
                                // Open terms
                            }
                            .font(.footnote)
                            
                            Button("Privacy Policy") {
                                // Open privacy policy
                            }
                            .font(.footnote)
                            
                            Button("Restore") {
                                // Restore purchases
                                print("Restore purchases")
                            }
                            .font(.footnote)
                        }
                        .foregroundColor(.blue)
                        
                        Text("Cancel anytime. No commitment.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top)
                }
                .padding()
            }
            .navigationTitle("Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

class SubscriptionViewModel: ObservableObject {
    @Published var isLoading = false
    
    init() {
        // Placeholder for subscription logic
    }
}

#Preview {
    SubscriptionView()
}
