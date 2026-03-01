# Web Photos - Modern Photo Management Interface

A Next.js-based web interface for the Immich photo management system with AI-powered search and face recognition.

## Features

- 🔍 **AI-Powered Search**: Semantic search using CLIP for natural language queries
- 👤 **Face Recognition**: Automatic face detection and person identification
- 📱 **Live Photos**: Support for iOS Live Photos with hover playback
- 🎯 **Smart Filtering**: Filter by date, location, camera, faces, and more
- 📚 **Album Management**: Create and organize photos into albums
- 🔐 **Multi-user Support**: JWT authentication with OAuth integration
- 📱 **Responsive Design**: Works on desktop, tablet, and mobile devices
- ⚡ **Virtual Scrolling**: Handles thousands of photos efficiently

## Prerequisites

- Node.js 18+ and npm
- Running RUST backend server (clip-service)
- Photos indexed in the backend system

## Getting Started

1. **Install dependencies**:
   ```bash
   cd web-photos
   npm install
   ```

2. **Configure environment** (optional):
   ```bash
   # Create .env.local if you need custom API URL
   echo "NEXT_PUBLIC_API_URL=http://localhost:3003/api" > .env.local
   ```

3. **Start development server**:
   ```bash
   npm run dev
   ```

4. **Access the application**:
   Open [http://localhost:3001](http://localhost:3001) in your browser

## Architecture

### Tech Stack
- **Framework**: Next.js 14 with App Router
- **Language**: TypeScript
- **Styling**: Tailwind CSS
- **State Management**: Zustand
- **Data Fetching**: TanStack Query (React Query)
- **Virtual Scrolling**: React Window
- **Icons**: Lucide React

### Project Structure
```
web-photos/
├── app/                    # Next.js App Router pages
│   ├── auth/              # Authentication page
│   ├── page.tsx           # Home page with photo grid
│   └── layout.tsx         # Root layout
├── components/            # React components
│   ├── auth/              # Authentication forms
│   ├── layout/            # Layout components (Header, etc.)
│   └── photos/            # Photo-related components
├── lib/                   # Utilities and configuration
│   ├── api/               # API client and endpoints
│   ├── stores/            # Zustand stores
│   └── types/             # TypeScript type definitions
└── public/                # Static assets
```

### API Integration
The web client communicates with the RUST backend server via REST APIs:

- **Authentication**: `/api/auth/*`
- **Photos**: `/api/photos/*`
- **Albums**: `/api/albums/*`
- **Faces**: `/api/faces/*`
- **Search**: `/api/search`
- **Images**: `/api/images/{asset_id}`

## Usage

### Authentication
1. Create an account or sign in with existing credentials
2. OAuth support for Google and GitHub (when configured)
3. JWT tokens stored securely with automatic refresh

### Photo Management
1. **ReIndex**: Click the ReIndex button to scan and process new photos
2. **Search**: Use natural language queries like "cats on beach" or "mountain sunset"
3. **Sort**: Sort photos by date, size, or filename
4. **Select**: Multi-select photos using Ctrl/Cmd+click or select all
5. **Filter**: Use filters for date ranges, locations, faces, etc.

### Live Photos
- iOS Live Photos are automatically detected during indexing
- Hover over Live Photo indicators (▶️) to see the motion
- Full support for HEIC/HEIF formats with MOV components

### Face Recognition
- Faces are automatically detected and grouped
- Access face management in Settings
- Add names and birth dates to identified faces
- Filter photos by specific people

## Development

### Running in Development
```bash
npm run dev      # Start development server on port 3001
npm run build    # Build for production
npm run lint     # Run ESLint
```

### Environment Variables
- `NEXT_PUBLIC_API_URL`: Backend API URL (default: http://localhost:3003/api)

## Static Export (No Next.js Server)

To build a fully static site that calls the Rust backend API directly:

- Set the API base URL (optional if `.env.local` already exists):
  - `echo "NEXT_PUBLIC_API_URL=http://localhost:3003/api" > .env.local`
- Build + export:
  - `npm run build:static`
- The static site is generated in `out/`. Serve it with any static host:
  - Local test: `npx serve out`
  - Or upload `out/` to S3/CloudFront, Netlify, GitHub Pages, Nginx, etc.

Notes:
- All API calls use `NEXT_PUBLIC_API_URL`; ensure your Rust API is reachable from the static host origin (CORS is allowed by the backend).
- Next.js API routes under `app/api/**` are not used in static mode; the UI talks to the Rust API directly.

### Proxy Configuration
The Next.js app proxies API requests to the RUST backend server automatically via `next.config.js` rewrites.

## Performance

- **Virtual Scrolling**: Efficiently handles thousands of photos
- **Image Optimization**: Next.js Image component with proper sizing
- **Lazy Loading**: Images load as they come into view
- **Caching**: React Query provides smart caching and background updates
- **Bundle Splitting**: Automatic code splitting for optimal loading

## Browser Support

- Chrome 88+
- Firefox 85+  
- Safari 14+
- Edge 88+

## Troubleshooting

### Common Issues

1. **Photos not loading**: Ensure the RUST backend is running and accessible
2. **Search not working**: Verify CLIP models are loaded in the backend
3. **Authentication errors**: Check JWT token expiration and backend connectivity

### Debugging
- Enable verbose logging by setting `NEXT_PUBLIC_DEBUG=true`
- Check browser dev tools Network tab for API request failures
- Verify backend server logs for processing errors

## See Also

- `reindex.md` — details the backend reindex pipeline and incremental face indexing (how new faces are detected and assigned during reindex).

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Commit your changes: `git commit -m 'Add amazing feature'`
4. Push to the branch: `git push origin feature/amazing-feature`
5. Open a Pull Request

## License

This project is part of the Immich photo management system.
