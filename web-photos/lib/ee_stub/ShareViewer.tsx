export default function ShareViewerStub({ shareId }: { shareId: string }) {
  return (
    <div className="p-6">
      <h1 className="text-2xl font-bold mb-2">Enterprise Feature</h1>
      <p className="text-muted-foreground">Shared link viewer is unavailable in this build.</p>
      <p className="text-sm text-muted-foreground mt-2">Share ID: {shareId}</p>
    </div>
  );
}

