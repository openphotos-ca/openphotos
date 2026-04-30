'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Plus, Trash2, FolderOpen } from 'lucide-react';
import { AlbumsManager } from '@/components/settings/AlbumsManager';
import AlbumPickerDialog from '@/components/albums/AlbumPickerDialog';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useToast } from '@/hooks/use-toast';
import { useAuthStore } from '@/lib/stores/auth';
import clsx from 'clsx';
import { logger } from '@/lib/logger';
import { photosApi } from '@/lib/api/photos';
import { useE2EEStore } from '@/lib/stores/e2ee';
import { cryptoApi } from '@/lib/api/crypto';
import { clearRememberedUMK } from '@/lib/remember';
import { PinInput } from '@/components/security/PinInput';
import { authApi } from '@/lib/api/auth';
import { isDemoEmail } from '@/lib/demo';
import { resolveApiBaseUrl } from '@/lib/api/base';

interface FoldersResponse {
  folders: string[];
  album_parent_id?: number | null;
  preserve_tree_path?: boolean;
}

interface ServerUpdateArtifact {
  platform: string;
  arch: string;
  url: string;
  sha256?: string | null;
}

interface ServerUpdateStatus {
  current_version: string;
  latest_version?: string | null;
  available: boolean;
  channel: string;
  checked_at?: string | null;
  status: 'disabled' | 'never_checked' | 'ok' | 'check_failed' | 'unsupported_install_mode';
  install_mode: 'docker' | 'linux-universal' | 'macos-pkg' | 'windows-nsis' | 'unknown';
  install_arch: string;
  install_supported: boolean;
  release_notes_url?: string | null;
  artifact?: ServerUpdateArtifact | null;
  install_command?: string | null;
  manual_steps: string[];
  last_error?: string | null;
}

function resolveConnectedServerUrl(apiBase: string): string {
  if (typeof window === 'undefined') return '-';
  try {
    const resolved = new URL(apiBase, window.location.origin);
    return resolved.origin;
  } catch {
    return window.location.origin;
  }
}

function formatCount(value?: number): string {
  return typeof value === 'number' && Number.isFinite(value)
    ? new Intl.NumberFormat().format(value)
    : 'Unavailable';
}

function formatBytes(value?: number): string {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return 'Unavailable';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let size = value;
  let unitIndex = 0;
  while (size >= 1000 && unitIndex < units.length - 1) {
    size /= 1000;
    unitIndex += 1;
  }
  return `${new Intl.NumberFormat(undefined, { maximumFractionDigits: unitIndex === 0 ? 0 : 2 }).format(size)} ${units[unitIndex]}`;
}

export default function SettingsPage() {
  const queryClient = useQueryClient();
  const [folders, setFolders] = useState<string[]>([]);
  const [newFolder, setNewFolder] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  // Album assignment for reindex session
  const [showAlbumPicker, setShowAlbumPicker] = useState(false);
  const [selectedAlbumId, setSelectedAlbumId] = useState<number | undefined>(undefined);
  const [selectedAlbumName, setSelectedAlbumName] = useState<string>('Root');
  const [preserveTreePath, setPreserveTreePath] = useState<boolean>(false);
  // Albums list from query cache to reflect create/delete instantly
  const { data: albums = [] } = useQuery({ queryKey: ['albums'], queryFn: () => photosApi.getAlbums(), staleTime: 60_000 });

  // Keep selected album label in sync with loaded albums
  useEffect(() => {
    if (selectedAlbumId) {
      const a = albums.find(a => a.id === selectedAlbumId);
      if (a) setSelectedAlbumName(a.name);
    } else {
      setSelectedAlbumName('Root');
    }
  }, [selectedAlbumId, albums]);
  const [faceSettings, setFaceSettings] = useState<{ min_quality: number; min_confidence: number; min_size: number; min_sharpness: number; yaw_max: number; yaw_hard_max: number; sharpness_target: number } | null>(null);
  const [isSavingFace, setIsSavingFace] = useState(false);
  // EE: Public link URL prefix
  const [eePublicPrefix, setEePublicPrefix] = useState<string>('');
  const [eePrefixLoading, setEePrefixLoading] = useState(false);
  const [eePrefixSaving, setEePrefixSaving] = useState(false);
  const [eePrefixError, setEePrefixError] = useState<string>('');
  // Security / PIN (E2EE)
  const e2ee = useE2EEStore();
  const [pinStatus, setPinStatus] = useState<{ is_set: boolean; verified: boolean } | null>(null);
  const [oldPin, setOldPin] = useState('');
  const [newPin, setNewPin] = useState('');
  const [newPin2, setNewPin2] = useState('');
  const [pinBusy, setPinBusy] = useState(false);
  const [pinError, setPinError] = useState('');
  const [pinSuccess, setPinSuccess] = useState('');
  const [oldVerified, setOldVerified] = useState(false);
  const { token } = useAuthStore();
  const { data: trashSettings, isFetching: trashLoading } = useQuery({ queryKey: ['trash-settings'], queryFn: () => photosApi.getTrashSettings(), staleTime: 60_000 });
  const [autoPurgeDays, setAutoPurgeDays] = useState<string>('30');
  useEffect(() => {
    if (trashSettings) setAutoPurgeDays(String(trashSettings.auto_purge_days ?? 0));
  }, [trashSettings]);
  const { data: libraryStats, isFetching: libraryStatsFetching, isError: libraryStatsError } = useQuery({
    queryKey: ['library-stats'],
    queryFn: () => photosApi.getMediaCounts({ include_locked: true }),
    enabled: !!token,
    staleTime: 0,
    refetchOnWindowFocus: false,
    retry: 0,
  });
  const [savingTrash, setSavingTrash] = useState(false);
  const [purgingTrash, setPurgingTrash] = useState(false);
  const [currentPassword, setCurrentPassword] = useState('');
  const [newAccountPassword, setNewAccountPassword] = useState('');
  const [confirmAccountPassword, setConfirmAccountPassword] = useState('');
  const [isChangingPassword, setIsChangingPassword] = useState(false);
  const [passwordError, setPasswordError] = useState<string>('');
  const [passwordSuccess, setPasswordSuccess] = useState<string>('');
  const { toast } = useToast();
  const router = useRouter();
  // Prefer env API when provided in dev, otherwise same-origin '/api'
  const API = resolveApiBaseUrl(process.env.NEXT_PUBLIC_API_URL || '/api');
  // EE capabilities gating
  const [isEE, setIsEE] = useState(false);
  const [serverVersion, setServerVersion] = useState<string | null>(null);
  const [capabilitiesLoading, setCapabilitiesLoading] = useState(true);
  const [connectedServerUrl, setConnectedServerUrl] = useState('-');
  const [serverUpdate, setServerUpdate] = useState<ServerUpdateStatus | null>(null);
  const [serverUpdateLoading, setServerUpdateLoading] = useState(false);
  const [serverUpdateChecking, setServerUpdateChecking] = useState(false);
  const [serverUpdateHidden, setServerUpdateHidden] = useState(false);
  const [serverUpdateError, setServerUpdateError] = useState<string | null>(null);
  const { user: me } = useAuthStore();
  const isAdmin = !!me && (me.role === 'owner' || me.role === 'admin');
  const isDemoUser = isDemoEmail(me?.email);
  const [isEmbedded, setIsEmbedded] = useState(false);

  const showDemoReadOnlyToast = () => {
    toast({
      title: 'Demo account',
      description: 'Demo account is read-only.',
      variant: 'destructive',
    });
  };

  const isDemoReadOnlyError = (error: unknown): boolean => {
    const text = error instanceof Error ? error.message : String(error ?? '');
    const lowered = text.toLowerCase();
    return lowered.includes('demo account is read-only') || lowered.includes('read-only');
  };
  useEffect(() => {
    let mounted = true;
    (async () => {
      if (mounted) setCapabilitiesLoading(true);
      try {
        const res = await fetch(`/api/capabilities?_=${Date.now()}`, { cache: 'no-store' });
        if (!res.ok) {
          if (mounted) {
            setIsEE(false);
            setServerVersion(null);
          }
          return;
        }
        const j = await res.json();
        if (mounted) {
          setIsEE(!!j?.ee);
          setServerVersion(typeof j?.version === 'string' && j.version.trim() ? j.version.trim() : null);
        }
      } catch {
        if (mounted) {
          setIsEE(false);
          setServerVersion(null);
        }
      } finally {
        if (mounted) setCapabilitiesLoading(false);
      }
    })();
    return () => { mounted = false; };
  }, []);

  useEffect(() => {
    try {
      setIsEmbedded(window.self !== window.top);
    } catch {
      setIsEmbedded(true);
    }
  }, []);

  useEffect(() => {
    setConnectedServerUrl(resolveConnectedServerUrl(API));
  }, [API]);

  const fetchServerUpdateStatus = async (method: 'GET' | 'POST' = 'GET') => {
    if (!token) return;
    if (method === 'POST') {
      setServerUpdateChecking(true);
    } else {
      setServerUpdateLoading(true);
    }

    try {
      const endpoint = method === 'POST' ? `${API}/server/update/check` : `${API}/server/update-status?_=${Date.now()}`;
      const res = await fetch(endpoint, {
        method,
        headers: { 'Authorization': `Bearer ${token}` },
        cache: 'no-store',
      });
      if (res.status === 403) {
        setServerUpdateHidden(true);
        setServerUpdate(null);
        setServerUpdateError(null);
        return;
      }

      const raw = await res.text();
      const payload = raw ? JSON.parse(raw) : null;
      if (!res.ok || !payload) {
        throw new Error(payload?.error || payload?.message || `Failed to load update status (${res.status})`);
      }

      setServerUpdateHidden(false);
      setServerUpdate(payload as ServerUpdateStatus);
      setServerUpdateError(null);
    } catch (error) {
      logger.warn('Failed to load server update status', error);
      setServerUpdateHidden(false);
      setServerUpdateError(error instanceof Error ? error.message : 'Failed to load update status');
    } finally {
      if (method === 'POST') {
        setServerUpdateChecking(false);
      } else {
        setServerUpdateLoading(false);
      }
    }
  };

  useEffect(() => {
    if (!token || !isAdmin) {
      setServerUpdate(null);
      setServerUpdateError(null);
      setServerUpdateHidden(false);
      setServerUpdateLoading(false);
      setServerUpdateChecking(false);
      return;
    }
    fetchServerUpdateStatus('GET');
  }, [API, isAdmin, token]);

  // Locked metadata inclusion settings
  const [secLoading, setSecLoading] = useState(false);
  const [secSaving, setSecSaving] = useState(false);
  const [includeLocation, setIncludeLocation] = useState(false);
  const [includeCaption, setIncludeCaption] = useState(false);
  const [includeDescription, setIncludeDescription] = useState(false);
  const [rememberMinutes, setRememberMinutes] = useState<number>(60);
  useEffect(() => {
    if (!token) return;
    setSecLoading(true);
    (async () => {
      try {
        const res = await fetch(`${API}/settings/security`, { headers: { 'Authorization': `Bearer ${token}` } });
        if (!res.ok) throw new Error(`Failed ${res.status}`);
        const j = await res.json();
        setIncludeLocation(!!j.include_location);
        setIncludeCaption(!!j.include_caption);
        setIncludeDescription(!!j.include_description);
        setRememberMinutes(typeof j.remember_minutes === 'number' ? Number(j.remember_minutes) : 60);
        try {
          localStorage.setItem('lockedMeta.include_location', j.include_location ? '1' : '0');
          localStorage.setItem('lockedMeta.include_caption', j.include_caption ? '1' : '0');
          localStorage.setItem('lockedMeta.include_description', j.include_description ? '1' : '0');
          localStorage.setItem('pin.remember.min', String(typeof j.remember_minutes === 'number' ? j.remember_minutes : 60));
        } catch {}
      } catch (e) {
        logger.warn('Failed to load security settings', e);
      } finally { setSecLoading(false); }
    })();
  }, [token]);

  // Appearance settings
  const [theme, setTheme] = useState<'system'|'light'|'dark'>(() => (typeof window !== 'undefined' ? ((localStorage.getItem('theme') as any) || 'system') : 'system'));
  const [accent, setAccent] = useState<'blue'|'indigo'|'purple'|'emerald'>(() => (typeof window !== 'undefined' ? ((localStorage.getItem('accent') as any) || 'blue') : 'blue'));

  const applyTheme = (t: 'system'|'light'|'dark') => {
    if (isDemoUser) return;
    setTheme(t);
    try {
      localStorage.setItem('theme', t);
    } catch {}
    try {
      const d = document.documentElement;
      const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
      const isDark = t === 'dark' || (t === 'system' && prefersDark);
      if (isDark) d.classList.add('dark'); else d.classList.remove('dark');
    } catch {}
  };

  const applyAccent = (a: 'blue'|'indigo'|'purple'|'emerald') => {
    if (isDemoUser) return;
    setAccent(a);
    try { localStorage.setItem('accent', a); } catch {}
    try { document.documentElement.setAttribute('data-accent', a); } catch {}
  };

  // React to system changes when on 'system'
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const handler = () => {
      if (theme === 'system') applyTheme('system');
    };
    mq.addEventListener?.('change', handler);
    return () => mq.removeEventListener?.('change', handler);
  }, [theme]);

  // Load user's folders and E2EE envelope on mount
  useEffect(() => {
    if (token) {
      loadFolders();
      loadFaceSettings();
      (async () => { try { await e2ee.loadEnvelope(); setPinStatus({ is_set: !!useE2EEStore.getState().envelope, verified: !!useE2EEStore.getState().umk }); } catch {} })();
    }
  }, [token]);

  // EE: Load public link URL prefix for admins
  useEffect(() => {
    if (!token || !isEE || !isAdmin) return;
    setEePrefixLoading(true); setEePrefixError('');
    (async () => {
      try {
        const res = await fetch(`${API}/ee/settings/public-link-prefix`, { headers: { 'Authorization': `Bearer ${token}` } });
        const j = await res.json().catch(()=>null);
        if (!res.ok || !j) throw new Error((j && j.message) || `Failed: ${res.status}`);
        setEePublicPrefix(String(j.prefix || ''));
      } catch (e:any) { setEePrefixError(e?.message || 'Failed to load'); }
      finally { setEePrefixLoading(false); }
    })();
  }, [token, isEE, isAdmin]);

  const connectedServerVersion = capabilitiesLoading
    ? 'Loading…'
    : (serverVersion || 'Unavailable');
  const libraryStatsLoading = !!token && libraryStatsFetching && !libraryStats;
  const libraryStatsUnavailable = !token || libraryStatsError;
  const libraryStatValue = (value?: number, formatter: (value?: number) => string = formatCount) => {
    if (libraryStatsLoading) return 'Loading…';
    if (libraryStatsUnavailable) return 'Unavailable';
    return formatter(value);
  };
  const showServerUpdateCard = isAdmin && !serverUpdateHidden;
  const serverUpdateLabel = (() => {
    if (serverUpdateLoading && !serverUpdate) return 'Checking…';
    switch (serverUpdate?.status) {
      case 'disabled':
        return 'Update checks disabled';
      case 'check_failed':
        return 'Check failed';
      case 'unsupported_install_mode':
        return 'Unsupported install mode';
      case 'ok':
        return serverUpdate.available ? 'Update available' : 'Up to date';
      default:
        if (serverUpdateError) return 'Unavailable';
        return 'Never checked';
    }
  })();
  const serverUpdateLastChecked = serverUpdate?.checked_at
    ? new Date(serverUpdate.checked_at).toLocaleString()
    : 'Never';
  const copyInstallCommand = async () => {
    if (!serverUpdate?.install_command) return;
    try {
      await navigator.clipboard.writeText(serverUpdate.install_command);
      toast({
        title: 'Install command copied',
        description: 'Run it on the server host to install the update.',
        variant: 'success',
      });
    } catch (error) {
      toast({
        title: 'Copy failed',
        description: error instanceof Error ? error.message : 'Unable to copy install command.',
        variant: 'destructive',
      });
    }
  };

  const loadFolders = async () => {
    setIsLoading(true);
    try {
      logger.debug('Loading folders, token:', token ? 'Present' : 'Missing');
      logger.debug('API URL:', API);
      
      if (!token) {
        toast({
          title: "Authentication required",
          description: "Please log in to manage folders",
          variant: "destructive",
        });
        return;
      }

      const response = await fetch(`${API}/settings/folders`, {
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
      });

      if (response.ok) {
        const data: FoldersResponse = await response.json();
        setFolders(data.folders);
        // Initialize album options from server
        const pid = (data.album_parent_id ?? undefined) || undefined;
        setSelectedAlbumId(pid);
        setPreserveTreePath(!!data.preserve_tree_path);
        setSelectedAlbumName('Root');
      } else {
        const errorData = await response.text();
        logger.error('Failed to load folders:', response.status, errorData);
        throw new Error(`Failed to load folders: ${response.status} ${errorData}`);
      }
    } catch (error) {
      logger.error('Error loading folders:', error);
      const errorMessage = error instanceof Error ? error.message : 'Failed to load folders';
      toast({
        title: "Error",
        description: errorMessage,
        variant: "destructive",
      });
    } finally {
      setIsLoading(false);
    }
  };

  const handleSaveTrashSettings = async () => {
    if (isDemoUser) {
      showDemoReadOnlyToast();
      return;
    }
    const parsed = Number(autoPurgeDays);
    if (Number.isNaN(parsed) || parsed < 0) {
      toast({ title: 'Invalid days', description: 'Enter a non-negative number of days.', variant: 'destructive' });
      return;
    }
    setSavingTrash(true);
    try {
      const res = await photosApi.updateTrashSettings(Math.min(365, Math.round(parsed)));
      setAutoPurgeDays(String(res.auto_purge_days));
      await queryClient.invalidateQueries({ queryKey: ['trash-settings'] });
      toast({ title: 'Trash settings saved', description: `Auto purge after ${res.auto_purge_days} day${res.auto_purge_days === 1 ? '' : 's'}.`, variant: 'success' });
    } catch (e: any) {
      if (isDemoReadOnlyError(e)) {
        showDemoReadOnlyToast();
        return;
      }
      toast({ title: 'Save failed', description: e?.message || String(e), variant: 'destructive' });
    } finally {
      setSavingTrash(false);
    }
  };

  const handleClearTrashNow = async () => {
    if (isDemoUser) {
      showDemoReadOnlyToast();
      return;
    }
    setPurgingTrash(true);
    try {
      const res = await photosApi.clearTrash();
      await queryClient.invalidateQueries({ queryKey: ['photos'] });
      await queryClient.invalidateQueries({ queryKey: ['media-counts'] });
      await queryClient.invalidateQueries({ queryKey: ['trash-settings'] });
      toast({ title: 'Trash cleared', description: `Removed ${res.purged} item${res.purged === 1 ? '' : 's'}.`, variant: 'success' });
    } catch (e: any) {
      if (isDemoReadOnlyError(e)) {
        showDemoReadOnlyToast();
        return;
      }
      toast({ title: 'Clear failed', description: e?.message || String(e), variant: 'destructive' });
    } finally {
      setPurgingTrash(false);
    }
  };

  const isPasswordFormValid =
    currentPassword.trim().length > 0 &&
    newAccountPassword.length >= 6 &&
    confirmAccountPassword === newAccountPassword;

  const handleChangePassword = async () => {
    if (isDemoUser) {
      showDemoReadOnlyToast();
      return;
    }
    setPasswordError('');
    setPasswordSuccess('');
    if (!isPasswordFormValid) return;
    setIsChangingPassword(true);
    try {
      await authApi.changePassword({
        current_password: currentPassword,
        new_password: newAccountPassword,
      });
      setPasswordSuccess('Password updated. Redirecting to login...');
      toast({ title: 'Password changed', description: 'Please sign in again.', variant: 'success' });
      useAuthStore.getState().logout();

      try {
        if (typeof window !== 'undefined' && window.top) {
          window.top.location.assign('/auth');
          return;
        }
      } catch {}
      router.push('/auth');
    } catch (e: any) {
      if (isDemoReadOnlyError(e)) {
        showDemoReadOnlyToast();
        return;
      }
      setPasswordError(e?.message || 'Failed to change password');
    } finally {
      setIsChangingPassword(false);
    }
  };

  const loadFaceSettings = async () => {
    try {
      if (!token) return;
      const res = await fetch(`${API}/settings/face`, {
        headers: {
          'Authorization': `Bearer ${token}`,
        },
      });
      if (res.ok) {
        const data = await res.json();
        setFaceSettings(data);
      }
    } catch (e) {
      logger.warn('Failed to load face settings', e);
    }
  };

  const saveFaceSettings = async () => {
    if (isDemoUser) {
      showDemoReadOnlyToast();
      return;
    }
    if (!token || !faceSettings) return;
    setIsSavingFace(true);
    try {
      const res = await fetch(`${API}/settings/face`, {
        method: 'PUT',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(faceSettings),
      });
      if (!res.ok) {
        const t = await res.text();
        throw new Error(`Failed to save face settings: ${res.status} ${t}`);
      }
    } catch (e) {
      if (isDemoReadOnlyError(e)) {
        showDemoReadOnlyToast();
        return;
      }
      logger.warn('Failed to save face settings', e);
    } finally {
      setIsSavingFace(false);
    }
  };

  const addFolder = () => {
    if (isDemoUser) {
      showDemoReadOnlyToast();
      return;
    }
    if (newFolder.trim() && !folders.includes(newFolder.trim())) {
      setFolders([...folders, newFolder.trim()]);
      setNewFolder('');
    }
  };

  

  const removeFolder = (index: number) => {
    if (isDemoUser) {
      showDemoReadOnlyToast();
      return;
    }
    setFolders(folders.filter((_, i) => i !== index));
  };

  const saveFolders = async () => {
    if (isDemoUser) {
      showDemoReadOnlyToast();
      return;
    }
    setIsSaving(true);
    try {
      if (!token) {
        toast({
          title: "Authentication required",
          description: "Please log in to save folders",
          variant: "destructive",
        });
        return;
      }

      const response = await fetch(`${API}/settings/folders`, {
        method: 'PUT',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          folders,
          album_parent_id: selectedAlbumId,
          preserve_tree_path: preserveTreePath,
        }),
      });

      if (response.ok) {
        const result = await response.json();
        let jobId: string | undefined = result?.job_id;

        // In Postgres mode the folders endpoint only updates settings and does not start indexing.
        // If no job_id is returned, explicitly start a reindex now.
        if (!jobId) {
          try {
            const r = await photosApi.reindexPhotos();
            jobId = r?.job_id;
          } catch (e) {
            // Fall through to close without progress UI; error toast below already covers failures
            logger.warn('reindexPhotos after save failed', e);
          }
        }

        if (jobId) {
          // Notify parent window (Header/ReindexProvider) when running inside iframe
          try {
            if (typeof window !== 'undefined' && window.parent) {
              window.parent.postMessage({ type: 'reindex-started', jobId }, window.location.origin);
              // Also request all modals (including Settings overlay) to close
              window.parent.postMessage({ type: 'close-modals' }, window.location.origin);
            }
          } catch {}
          // Do not navigate inside the iframe; parent will keep user on the grid
        } else {
          // No job id returned — just ask parent to close settings if embedded, otherwise go home
          try {
            if (typeof window !== 'undefined' && window.parent && window.parent !== window) {
              window.parent.postMessage({ type: 'close-modals' }, window.location.origin);
            } else {
              router.push('/');
            }
          } catch {}
        }
      } else {
        const error = await response.json();
        throw new Error(error.error || 'Failed to save folders');
      }
    } catch (error) {
      if (isDemoReadOnlyError(error)) {
        showDemoReadOnlyToast();
        return;
      }
      logger.error('Error saving folders:', error);
      toast({
        title: "Error",
        description: error instanceof Error ? error.message : "Failed to save folders",
        variant: "destructive",
      });
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <div className={clsx('container mx-auto px-4', isEmbedded ? 'pt-3 pb-8' : 'py-8')}>
      <div className="max-w-2xl mx-auto">
        <div className={clsx('flex items-center justify-between gap-4 mb-8 min-h-10', isEmbedded && 'pl-14')}>
          <h1 className="text-3xl font-bold">Settings</h1>
        </div>
        {isDemoUser && (
          <div className="mb-6 rounded-md border border-amber-500/40 bg-amber-500/10 px-4 py-3 text-sm text-amber-200">
            Demo account: settings are read-only.
          </div>
        )}
        <Card className="mb-8">
          <CardHeader>
            <CardTitle>Cloud Library</CardTitle>
            <CardDescription>Active cloud media stored for this account.</CardDescription>
          </CardHeader>
          <CardContent>
            <div className="grid gap-4 sm:grid-cols-3">
              <div>
                <Label className="text-xs uppercase tracking-wide text-muted-foreground">Photos</Label>
                <div className="mt-1 text-sm text-foreground">{libraryStatValue(libraryStats?.photos)}</div>
              </div>
              <div>
                <Label className="text-xs uppercase tracking-wide text-muted-foreground">Videos</Label>
                <div className="mt-1 text-sm text-foreground">{libraryStatValue(libraryStats?.videos)}</div>
              </div>
              <div>
                <Label className="text-xs uppercase tracking-wide text-muted-foreground">Total Size</Label>
                <div className="mt-1 text-sm text-foreground">{libraryStatValue(libraryStats?.total_size_bytes, formatBytes)}</div>
              </div>
            </div>
          </CardContent>
        </Card>
        <Card className="mb-8">
          <CardHeader>
            <CardTitle>Connection</CardTitle>
            <CardDescription>Current backend connection details.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div>
              <Label className="text-xs uppercase tracking-wide text-muted-foreground">Server URL</Label>
              <div className="mt-1 break-all text-sm text-foreground">{connectedServerUrl}</div>
            </div>
            <div>
              <Label className="text-xs uppercase tracking-wide text-muted-foreground">Server Version</Label>
              <div className="mt-1 text-sm text-foreground">{connectedServerVersion}</div>
            </div>
          </CardContent>
        </Card>
        {showServerUpdateCard && (
          <Card className="mb-8">
            <CardHeader>
              <CardTitle>Server Update</CardTitle>
              <CardDescription>Admin-only server release status and install steps for native or Docker deployments.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="grid gap-4 sm:grid-cols-2">
                <div>
                  <Label className="text-xs uppercase tracking-wide text-muted-foreground">Status</Label>
                  <div className="mt-1 text-sm text-foreground">{serverUpdateLabel}</div>
                </div>
                <div>
                  <Label className="text-xs uppercase tracking-wide text-muted-foreground">Last Checked</Label>
                  <div className="mt-1 text-sm text-foreground">{serverUpdateLastChecked}</div>
                </div>
                <div>
                  <Label className="text-xs uppercase tracking-wide text-muted-foreground">Current Version</Label>
                  <div className="mt-1 text-sm text-foreground">{serverUpdate?.current_version || connectedServerVersion}</div>
                </div>
                <div>
                  <Label className="text-xs uppercase tracking-wide text-muted-foreground">Latest Version</Label>
                  <div className="mt-1 text-sm text-foreground">{serverUpdate?.latest_version || 'Unavailable'}</div>
                </div>
                <div>
                  <Label className="text-xs uppercase tracking-wide text-muted-foreground">Install Mode</Label>
                  <div className="mt-1 text-sm text-foreground">{serverUpdate?.install_mode || 'unknown'} / {serverUpdate?.install_arch || '-'}</div>
                </div>
                <div>
                  <Label className="text-xs uppercase tracking-wide text-muted-foreground">Channel</Label>
                  <div className="mt-1 text-sm text-foreground">{serverUpdate?.channel || 'stable'}</div>
                </div>
              </div>
              {serverUpdate?.artifact?.url && (
                <div>
                  <Label className="text-xs uppercase tracking-wide text-muted-foreground">Installer</Label>
                  <div className="mt-1 break-all text-sm text-foreground">{serverUpdate.artifact.url}</div>
                </div>
              )}
              {(serverUpdate?.last_error || serverUpdateError) && (
                <div className="rounded-md border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm text-amber-200">
                  {serverUpdate?.last_error || serverUpdateError}
                </div>
              )}
              {serverUpdate?.available && serverUpdate.manual_steps.length > 0 && (
                <div>
                  <Label className="text-xs uppercase tracking-wide text-muted-foreground">Install Steps</Label>
                  <ol className="mt-2 space-y-1 list-decimal pl-5 text-sm text-muted-foreground">
                    {serverUpdate.manual_steps.map((step) => (
                      <li key={step}>{step}</li>
                    ))}
                  </ol>
                </div>
              )}
              <div className="flex flex-wrap gap-3">
                <Button onClick={() => fetchServerUpdateStatus('POST')} disabled={serverUpdateChecking || isDemoUser}>
                  {serverUpdateChecking ? 'Checking…' : 'Check now'}
                </Button>
                {serverUpdate?.release_notes_url && (
                  <Button
                    variant="ghost"
                    onClick={() => window.open(serverUpdate.release_notes_url!, '_blank', 'noopener,noreferrer')}
                  >
                    Open release notes
                  </Button>
                )}
                {serverUpdate?.available && serverUpdate?.artifact?.url && (
                  <Button
                    variant="ghost"
                    onClick={() => window.open(serverUpdate.artifact!.url, '_blank', 'noopener,noreferrer')}
                  >
                    Download installer
                  </Button>
                )}
                {serverUpdate?.install_command && (
                  <Button variant="ghost" onClick={copyInstallCommand}>
                    Copy install command
                  </Button>
                )}
              </div>
              <p className="text-sm text-muted-foreground">
                Apply updates directly on the server or Docker host using the instructions above.
              </p>
            </CardContent>
          </Card>
        )}
        <fieldset
          disabled={isDemoUser}
          className={clsx('border-0 p-0 m-0 min-w-0', isDemoUser && 'opacity-70')}
        >

        {/* Appearance */}
        <Card className="mb-8">
          <CardHeader>
            <CardTitle>Appearance</CardTitle>
            <CardDescription>Choose theme and accent color.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-6">
            <div>
              <Label className="mb-2 block">Theme</Label>
              <div className="flex gap-2" role="group" aria-label="Theme">
                {(['system','light','dark'] as const).map(t => (
                  <button
                    key={t}
                    onClick={() => applyTheme(t)}
                    className={clsx('px-3 py-1.5 rounded-full border text-sm', theme === t ? 'bg-primary/10 text-primary border-primary/30' : 'bg-card text-foreground border-border hover:bg-muted')}
                    aria-pressed={theme === t}
                  >
                    {t[0].toUpperCase() + t.slice(1)}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <Label className="mb-2 block">Accent</Label>
              <div className="flex gap-3 items-center">
                {([
                  {k:'blue', cls:'bg-blue-600'},
                  {k:'indigo', cls:'bg-indigo-600'},
                  {k:'purple', cls:'bg-purple-600'},
                  {k:'emerald', cls:'bg-emerald-600'},
                ] as const).map(({k, cls}) => (
                  <button
                    key={k}
                    onClick={() => applyAccent(k as any)}
                    className={clsx('w-8 h-8 rounded-full border-2', cls, accent === k ? 'ring-2 ring-offset-2 ring-primary' : 'border-white')}
                    aria-label={`Accent ${k}`}
                    aria-pressed={accent === k}
                    title={k}
                  />
                ))}
              </div>
            </div>
          </CardContent>
        </Card>

        <Card className="mt-8">
          <CardHeader>
            <CardTitle>Change Password</CardTitle>
            <CardDescription>Update your account password. You will be signed out after a successful change.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div>
              <Label htmlFor="currentPassword">Current Password</Label>
              <Input
                id="currentPassword"
                type="password"
                autoComplete="current-password"
                value={currentPassword}
                onChange={(e) => {
                  setCurrentPassword(e.target.value);
                  setPasswordError('');
                  setPasswordSuccess('');
                }}
                disabled={isChangingPassword}
              />
            </div>
            <div>
              <Label htmlFor="newAccountPassword">New Password</Label>
              <Input
                id="newAccountPassword"
                type="password"
                autoComplete="new-password"
                value={newAccountPassword}
                onChange={(e) => {
                  setNewAccountPassword(e.target.value);
                  setPasswordError('');
                  setPasswordSuccess('');
                }}
                disabled={isChangingPassword}
              />
              <p className="text-xs text-muted-foreground mt-1">Minimum 6 characters.</p>
            </div>
            <div>
              <Label htmlFor="confirmAccountPassword">Confirm New Password</Label>
              <Input
                id="confirmAccountPassword"
                type="password"
                autoComplete="new-password"
                value={confirmAccountPassword}
                onChange={(e) => {
                  setConfirmAccountPassword(e.target.value);
                  setPasswordError('');
                  setPasswordSuccess('');
                }}
                disabled={isChangingPassword}
              />
            </div>
            {confirmAccountPassword.length > 0 && newAccountPassword !== confirmAccountPassword && (
              <p className="text-sm text-red-600">Passwords do not match.</p>
            )}
            {newAccountPassword.length > 0 && newAccountPassword.length < 6 && (
              <p className="text-sm text-red-600">Password must be at least 6 characters.</p>
            )}
            {passwordError && <p className="text-sm text-red-600">{passwordError}</p>}
            {passwordSuccess && <p className="text-sm text-green-600">{passwordSuccess}</p>}
            <div className="flex justify-end">
              <Button onClick={handleChangePassword} disabled={isChangingPassword || !isPasswordFormValid}>
                {isChangingPassword ? 'Changing...' : 'Change Password'}
              </Button>
            </div>
          </CardContent>
        </Card>

        {/* Security / PIN */}
        <Card className="mt-8">
          <CardHeader className="flex items-start justify-between gap-3">
            <div>
              <CardTitle>Security</CardTitle>
              <CardDescription>Manage End‑to‑End Encryption and locked metadata.</CardDescription>
            </div>
            {true && (
              <span className={`inline-flex items-center px-2 py-0.5 text-xs rounded-full border ${useE2EEStore.getState().envelope ? 'border-green-400/30 text-green-300 bg-green-400/10' : 'border-yellow-400/30 text-yellow-300 bg-yellow-400/10'}`}>
                {useE2EEStore.getState().envelope ? (useE2EEStore.getState().umk ? 'Set (unlocked)' : 'Set') : 'Not set'}
              </span>
            )}
          </CardHeader>
          <CardContent className="space-y-4">
            {(
              <>
                <div className="mx-auto max-w-md space-y-5">
                {useE2EEStore.getState().envelope ? (
                  <>
                    {/* Step 1: Verify current PIN */}
                    <div>
                      <Label className="block mb-2 text-base">Change PIN - Current PIN:</Label>
                      <PinInput value={oldPin} onChange={(v)=>{ setOldPin(v); setPinError(''); setPinSuccess(''); }} ariaLabel="Current PIN" />
                      {oldPin.length > 0 && oldPin.length < 8 && (
                        <div className="mt-1 text-xs text-muted-foreground">{oldPin.length}/8</div>
                      )}
                      {pinError && !oldVerified && <div className="mt-1 text-sm text-red-500" role="alert">{pinError}</div>}
                      {oldVerified && <div className="mt-1 text-sm text-green-500">Verified</div>}
                      <div className="mt-3">
                        <Button variant="ghost" disabled={pinBusy || oldPin.length !== 8 || oldVerified} onClick={async () => {
                          setPinError(''); setPinSuccess(''); setPinBusy(true);
                          try {
                            const env = useE2EEStore.getState().envelope;
                            if (!env) throw new Error('No envelope');
                            // @ts-ignore
                            const worker = new Worker(new URL('../../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
                            const umkB64: string = await new Promise((resolve, reject) => {
                              worker.onmessage = (ev: MessageEvent) => { const d:any = ev.data; if (d?.ok && d.kind === 'umk') { try { worker.terminate(); } catch {}; resolve(d.umkB64); } else if (d?.ok===false) { try{worker.terminate();}catch{}; reject(new Error(d.error||'verify failed')); } };
                              worker.onerror = (e) => { try{worker.terminate();}catch{}; reject(e.error||new Error(String(e.message||e))); };
                              worker.postMessage({ type: 'unwrap-umk', password: oldPin, envelope: env });
                            });
                            // Keep UMK only when we truly want to unlock now; for verify we just mark verified
                            setOldVerified(true);
                          } catch (e: any) {
                            const msg = (e?.message || '').toString();
                            setPinError(msg || 'Incorrect PIN');
                          } finally { setPinBusy(false); }
                        }}> {oldVerified ? 'Verified' : 'Verify'} </Button>
                      </div>
                    </div>

                    {/* Step 2: New PIN */}
                    {oldVerified && (
                      <div className="pt-2 space-y-3">
                        <div>
                          <Label className="block mb-2 text-base">New PIN</Label>
                          <PinInput value={newPin} onChange={(v)=>{ setNewPin(v); setPinError(''); setPinSuccess(''); }} ariaLabel="New PIN" />
                          <div className="mt-1 text-xs text-muted-foreground">8 characters. Avoid obvious patterns.</div>
                        </div>
                        <div>
                          <Label className="block mb-2 text-base">Confirm PIN</Label>
                          <PinInput value={newPin2} onChange={(v)=>{ setNewPin2(v); setPinError(''); setPinSuccess(''); }} ariaLabel="Confirm PIN" />
                          {newPin2.length === 8 && newPin !== newPin2 && (
                            <div className="mt-1 text-sm text-red-500">PINs do not match</div>
                          )}
                        </div>
                        {pinSuccess && <div className="text-sm text-green-500">{pinSuccess}</div>}
                        {pinError && oldVerified && <div className="text-sm text-red-500">{pinError}</div>}
                        <div>
                          <Button disabled={pinBusy || newPin.length !== 8 || newPin2.length !== 8 || newPin !== newPin2} onClick={async () => {
                            setPinError(''); setPinSuccess(''); setPinBusy(true);
                            try {
                              const umk = useE2EEStore.getState().umk;
                              if (!umk) throw new Error('Unlock first');
                              let umkHex = ''; for (let i=0;i<umk.length;i++) umkHex += umk[i].toString(16).padStart(2,'0');
                              // @ts-ignore
                              const worker = new Worker(new URL('../../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
                              const env: any = await new Promise((resolve, reject) => {
                                worker.onmessage = (ev: MessageEvent) => { const d:any = ev.data; if (d?.ok && d.kind === 'envelope') { try { worker.terminate(); } catch {}; resolve(d.envelope); } else if (d?.ok===false) { try{worker.terminate();}catch{}; reject(new Error(d.error||'wrap failed')); } };
                                worker.onerror = (e) => { try{worker.terminate();}catch{}; reject(e.error||new Error(String(e.message||e))); };
                                const params = useE2EEStore.getState().params || { m: 128, t: 3, p: 1 };
                                worker.postMessage({ type: 'wrap-umk', umkHex, password: newPin, params });
                              });
                              await cryptoApi.saveEnvelope(env);
                              useE2EEStore.setState({ envelope: env, envelopeUpdatedAt: new Date().toISOString() });
                              // For clarity and safety, lock the session after changing the PIN.
                              // The user will re-unlock with the new PIN as needed.
                              useE2EEStore.getState().setUMK(null);
                              try { clearRememberedUMK(); } catch {}
                              setOldPin(''); setNewPin(''); setNewPin2(''); setOldVerified(false);
                              setPinSuccess('PIN changed successfully');
                              toast({ title: 'PIN changed', description: 'Your PIN has been updated.', variant: 'success' });
                            } catch (e:any) { setPinError(e?.message||'Failed to change PIN'); }
                            finally { setPinBusy(false); }
                          }}> {pinBusy ? 'Saving…' : 'Change PIN'} </Button>
                        </div>
                      </div>
                    )}
                  </>
                ) : (
                  <>
                    <div className="space-y-3">
                      <div>
                        <Label className="block mb-2 text-base">New PIN</Label>
                        <PinInput value={newPin} onChange={(v)=>{ setNewPin(v); setPinError(''); setPinSuccess(''); }} ariaLabel="New PIN" />
                        <div className="mt-1 text-xs text-muted-foreground">8 characters. Avoid obvious patterns.</div>
                      </div>
                      <div>
                        <Label className="block mb-2 text-base">Confirm PIN</Label>
                        <PinInput value={newPin2} onChange={(v)=>{ setNewPin2(v); setPinError(''); setPinSuccess(''); }} ariaLabel="Confirm New PIN" />
                        {newPin2.length === 8 && newPin !== newPin2 && (
                          <div className="mt-1 text-sm text-red-500">PINs do not match</div>
                        )}
                      </div>
                      {pinError && <div className="text-sm text-red-500">{pinError}</div>}
                      {pinSuccess && <div className="text-sm text-green-500">{pinSuccess}</div>}
                      <div>
                        <Button disabled={pinBusy || newPin.length !== 8 || newPin2.length !== 8 || newPin !== newPin2} onClick={async () => {
                          setPinError(''); setPinSuccess(''); setPinBusy(true);
                          try {
                            // Generate UMK and wrap
                            const umk = new Uint8Array(32); crypto.getRandomValues(umk);
                            let umkHex = ''; for (let i=0;i<umk.length;i++) umkHex += umk[i].toString(16).padStart(2,'0');
                            // @ts-ignore
                            const worker = new Worker(new URL('../../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
                            const env: any = await new Promise((resolve, reject) => {
                              worker.onmessage = (ev: MessageEvent) => { const d:any = ev.data; if (d?.ok && d.kind === 'envelope') { try { worker.terminate(); } catch {}; resolve(d.envelope); } else if (d?.ok===false) { try{worker.terminate();}catch{}; reject(new Error(d.error||'wrap failed')); } };
                              worker.onerror = (e) => { try{worker.terminate();}catch{}; reject(e.error||new Error(String(e.message||e))); };
                              const params = useE2EEStore.getState().params || { m: 128, t: 3, p: 1 };
                              worker.postMessage({ type: 'wrap-umk', umkHex, password: newPin, params });
                            });
                            await cryptoApi.saveEnvelope(env);
                            useE2EEStore.getState().setUMK(umk);
                            useE2EEStore.setState({ envelope: env, envelopeUpdatedAt: new Date().toISOString() });
                            setNewPin(''); setNewPin2('');
                            setPinSuccess('PIN set successfully');
                            toast({ title: 'PIN set', description: 'Your PIN has been created.', variant: 'success' });
                          } catch (e:any) { setPinError(e?.message||'Failed to set PIN'); }
                          finally { setPinBusy(false); }
                        }}> {pinBusy ? 'Saving…' : 'Set PIN'} </Button>
                      </div>
                    </div>
                  </>
                )}
                </div>
              </>
            )}
            {/* Divider between subsections */}
            <div className="my-6 border-t border-border" />
            {/* Encryption performance */}
            <div className="mt-6 space-y-4">
              <div className="text-sm font-medium">Encryption Performance</div>
              <div className="grid gap-3 md:grid-cols-[220px_auto] items-end">
                <div>
                  <Label htmlFor="batchConcurrency">Batch Concurrency</Label>
                  <Input id="batchConcurrency" type="number" min={1} max={6}
                    defaultValue={(typeof window!=='undefined' ? (localStorage.getItem('batchConcurrency') || '2') : '2')}
                    onBlur={(e)=>{
                      const v = parseInt(e.currentTarget.value||'2',10);
                      const n = Math.min(6, Math.max(1, isNaN(v)?2:v));
                      try { localStorage.setItem('batchConcurrency', String(n)); } catch {}
                      toast({ title: 'Saved', description: `Batch concurrency set to ${n}`, variant: 'success' });
                      e.currentTarget.value = String(n);
                    }} />
                  <p className="text-xs text-muted-foreground mt-1">How many items to encrypt/decrypt in parallel (1–6).</p>
                </div>
                <div className="flex items-end justify-end">
                  <Button onClick={() => {
                    try {
                      // @ts-ignore
                      const worker = new Worker(new URL('../../workers/e2ee.worker.ts', import.meta.url), { type: 'module' });
                      worker.onmessage = (ev: MessageEvent) => {
                        const d:any = ev.data; if (d?.ok && d.kind === 'calibrated') {
                          useE2EEStore.getState().setParams(d.params);
                          useE2EEStore.setState({ canEncrypt: true });
                          try { worker.terminate(); } catch {}
                          toast({ title: 'Calibrated', description: `m=${d.params.m}MiB t=${d.params.t} p=${d.params.p}`, variant: 'success' });
                        }
                      };
                      worker.postMessage({ type: 'calibrate-argon2', targetMs: 300 });
                    } catch (e:any) { toast({ title: 'Calibration failed', description: e?.message||String(e), variant: 'destructive' }); }
                  }}>Re‑calibrate Encryption</Button>
                </div>
              </div>
            </div>

            {/* Locked metadata inclusion */}
            <div className="my-6 border-t border-border" />
            <div className="mt-6 space-y-3">
              <div className="text-sm font-medium">Metadata included in locked media</div>
              <div className="text-xs text-muted-foreground mb-1">Always included</div>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
                {['Capture time','File size','Dimensions','Orientation','Media type'].map((label) => (
                  <label key={label} className="inline-flex items-center gap-2 text-sm opacity-70">
                    <input type="checkbox" checked readOnly disabled />
                    <span>{label}</span>
                  </label>
                ))}
              </div>
              <div className="text-xs text-muted-foreground mt-3">Optional (stored alongside encrypted content)</div>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
                <label className="inline-flex items-center gap-2 text-sm">
                  <input type="checkbox" className="accent-primary" checked={includeLocation} onChange={(e)=>setIncludeLocation(e.currentTarget.checked)} disabled={secLoading||secSaving} />
                  <span>Location data (GPS & place names)</span>
                </label>
                <label className="inline-flex items-center gap-2 text-sm">
                  <input type="checkbox" className="accent-primary" checked={includeCaption} onChange={(e)=>setIncludeCaption(e.currentTarget.checked)} disabled={secLoading||secSaving} />
                  <span>Caption</span>
                </label>
                <label className="inline-flex items-center gap-2 text-sm">
                  <input type="checkbox" className="accent-primary" checked={includeDescription} onChange={(e)=>setIncludeDescription(e.currentTarget.checked)} disabled={secLoading||secSaving} />
                  <span>Description</span>
                </label>
              </div>
            </div>

            {/* Remember unlock */}
            <div className="my-6 border-t border-border" />
            <div className="mt-6 space-y-2">
              <div className="text-sm font-medium">Remember unlock</div>
              <div className="text-xs text-muted-foreground">If enabled, your device remembers the unlocked key locally and won’t prompt for PIN again until it expires.</div>
              <div className="flex items-center gap-2">
                <select
                  className="px-2 py-1.5 border border-border rounded bg-background"
                  value={rememberMinutes}
                  onChange={(e)=> setRememberMinutes(Number(e.target.value))}
                  disabled={secLoading||secSaving}
                >
                  <option value={0}>Off</option>
                  <option value={15}>15 minutes</option>
                  <option value={60}>1 hour</option>
                  <option value={240}>4 hours</option>
                  <option value={1440}>24 hours</option>
                </select>
                <div className="text-xs text-muted-foreground">Stored only on this device</div>
              </div>
            </div>

            {/* Save all security settings */}
            <div className="mt-6 flex items-center justify-end">
              <Button disabled={secLoading||secSaving} onClick={async ()=>{
                if (isDemoUser) {
                  showDemoReadOnlyToast();
                  return;
                }
                if (!token) return;
                setSecSaving(true);
                try {
                  const res = await fetch(`${API}/settings/security`, { method: 'PUT', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ include_location: includeLocation, include_caption: includeCaption, include_description: includeDescription, remember_minutes: rememberMinutes }) });
                  if (!res.ok) throw new Error(`Failed ${res.status}`);
                  const j = await res.json();
                  try {
                    localStorage.setItem('lockedMeta.include_location', j.include_location ? '1' : '0');
                    localStorage.setItem('lockedMeta.include_caption', j.include_caption ? '1' : '0');
                    localStorage.setItem('lockedMeta.include_description', j.include_description ? '1' : '0');
                    localStorage.setItem('pin.remember.min', String(typeof j.remember_minutes === 'number' ? j.remember_minutes : 60));
                  } catch {}
                  toast({ title: 'Saved', description: 'Security settings updated.' });
                } catch (e:any) {
                  if (isDemoReadOnlyError(e)) {
                    showDemoReadOnlyToast();
                    return;
                  }
                  toast({ title: 'Save failed', description: e?.message||String(e), variant: 'destructive' });
                } finally { setSecSaving(false); }
              }}>{secSaving ? 'Saving…' : 'Save security settings'}</Button>
            </div>
          </CardContent>
        </Card>

        

        <Card className="mt-8">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Trash2 className="h-5 w-5" />
              Trash Management
            </CardTitle>
            <CardDescription>
              Control how long deleted items stay in the trash before being removed permanently.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="grid gap-3 md:grid-cols-[220px_auto]">
              <div>
                <Label htmlFor="autoPurgeDays">Auto purge after (days)</Label>
                <Input
                  id="autoPurgeDays"
                  type="number"
                  min={0}
                  max={365}
                  value={autoPurgeDays}
                  onChange={(e) => setAutoPurgeDays(e.target.value)}
                  disabled={trashLoading || savingTrash}
                />
                <p className="text-xs text-muted-foreground mt-1">Set to 0 to keep items until cleared manually. Maximum 365 days.</p>
              </div>
              <div className="flex items-end">
                <Button onClick={handleSaveTrashSettings} disabled={trashLoading || savingTrash}>
                  {savingTrash ? 'Saving…' : 'Save'}
                </Button>
              </div>
            </div>
            <div className="flex items-center gap-3">
              <Button variant="destructive" onClick={handleClearTrashNow} disabled={trashLoading || purgingTrash}>
                {purgingTrash ? 'Clearing…' : 'Clear Trash'}
              </Button>
              <p className="text-sm text-muted-foreground">Permanently deletes all items currently in the trash.</p>
            </div>
          </CardContent>
        </Card>

        <Card className="mt-8">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <FolderOpen className="h-5 w-5" />
              Indexed Folders
            </CardTitle>
            <CardDescription>
              Specify which folders should be indexed for photo search. Adding or changing folders will automatically start reindexing.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            {/* Add new folder */}
            <div className="flex gap-2">
              <div className="flex-1">
                <Label htmlFor="newFolder">Add Folder Path</Label>
                <Input
                  id="newFolder"
                  placeholder="/path/to/your/photos"
                  value={newFolder}
                  onChange={(e) => setNewFolder(e.target.value)}
                  onKeyPress={(e) => e.key === 'Enter' && addFolder()}
                />
              </div>
              <div className="flex items-end">
                <Button onClick={addFolder} disabled={!newFolder.trim()}>
                  <Plus className="h-4 w-4" />
                </Button>
              </div>
              </div>

            {/* Album assignment controls for this indexing run */}
            <div className="space-y-3 pt-2">
              <div className="flex items-end gap-3">
                <div className="flex-1">
                  <Label>Add under {selectedAlbumId ? `${selectedAlbumName}` : 'Root'} album</Label>
                </div>
                <Button
                  type="button"
                  variant="ghost"
                  onClick={() => setShowAlbumPicker(true)}
                >
                  Album Tree
                </Button>
              </div>
              <div className="flex items-center gap-3">
                <label className="inline-flex items-center gap-2 text-sm select-none">
                  <input
                    type="checkbox"
                    checked={preserveTreePath}
                    onChange={(e) => setPreserveTreePath(e.target.checked)}
                  />
                  Preserve tree path
                </label>
              </div>
            </div>

            {/* Folders list */}
            {isLoading ? (
              <div className="text-center py-4">Loading folders...</div>
            ) : (
              <div className="space-y-2">
                <Label>Current Folders ({folders.length})</Label>
                {folders.length === 0 ? (
                  <div className="text-muted-foreground text-center py-8">
                    No folders configured. Add a folder above to start indexing photos.
                  </div>
                ) : (
                  folders.map((folder, index) => (
                    <div key={index} className="flex items-center gap-2 p-3 bg-muted rounded-md">
                      <FolderOpen className="h-4 w-4 text-muted-foreground" />
                      <span className="flex-1 font-mono text-sm">{folder}</span>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => removeFolder(index)}
                      >
                        <Trash2 className="h-4 w-4 text-destructive" />
                      </Button>
                    </div>
                  ))
                )}
              </div>
            )}

            {/* Save button */}
            <div className="pt-4">
              <Button 
                onClick={saveFolders} 
                disabled={isSaving || folders.length === 0}
                className="w-full"
              >
                {isSaving ? 'Saving...' : 'Save & Start Indexing'}
              </Button>
            </div>
          </CardContent>
        </Card>

        {/* Face Quality Settings */}
        <Card className="mt-8">
          <CardHeader>
            <CardTitle>Face Quality</CardTitle>
            <CardDescription>Control which faces are kept and shown in the filter.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            {!faceSettings ? (
              <div className="text-muted-foreground">Loading face settings…</div>
            ) : (
              <>
                <div>
                  <Label>Quality Threshold ({faceSettings.min_quality?.toFixed(2)})</Label>
                  <input type="range" className="w-full" min={0.3} max={0.9} step={0.01}
                    value={faceSettings.min_quality}
                    onChange={(e)=>setFaceSettings({...faceSettings!, min_quality: parseFloat(e.target.value)})} />
                </div>
                <div className="grid grid-cols-3 gap-4">
                  <div>
                    <Label>Min Confidence</Label>
                    <Input type="number" step="0.01" min={0} max={1} value={faceSettings.min_confidence}
                      onChange={(e)=>setFaceSettings({...faceSettings!, min_confidence: parseFloat(e.target.value)})} />
                  </div>
                  <div>
                    <Label>Min Size (px)</Label>
                    <Input type="number" min={32} max={256} value={faceSettings.min_size}
                      onChange={(e)=>setFaceSettings({...faceSettings!, min_size: parseInt(e.target.value)})} />
                  </div>
                  <div>
                    <Label>Min Sharpness</Label>
                    <Input type="number" step="0.01" min={0} max={1} value={faceSettings.min_sharpness}
                      onChange={(e)=>setFaceSettings({...faceSettings!, min_sharpness: parseFloat(e.target.value)})} />
                  </div>
                </div>
                <div className="pt-2">
                  <Button onClick={saveFaceSettings} disabled={isSavingFace}>
                    {isSavingFace ? 'Saving…' : 'Save Face Settings'}
                  </Button>
                </div>
              </>
            )}
          </CardContent>
        </Card>

        {/* EE: Public Links settings (admin only) */}
        {isEE && isAdmin && (
          <Card className="mt-8">
            <CardHeader>
              <CardTitle>Enterprise — Public Links</CardTitle>
              <CardDescription>Configure the URL prefix used to generate public links.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div>
                <Label>Public link URL prefix</Label>
                <Input
                  placeholder="https://photos.example.com"
                  value={eePublicPrefix}
                  onChange={(e)=> setEePublicPrefix(e.target.value)}
                  disabled={eePrefixLoading || eePrefixSaving}
                />
                <div className="text-xs text-muted-foreground mt-1">
                  Optional. If blank, links use the current site’s host and port (respecting proxy headers).
                </div>
              </div>
              {eePrefixError && <div className="text-sm text-red-600">{eePrefixError}</div>}
              <div className="flex items-center gap-2">
                <Button
                  onClick={async () => {
                    if (isDemoUser) {
                      showDemoReadOnlyToast();
                      return;
                    }
                    if (!token) return;
                    setEePrefixSaving(true); setEePrefixError('');
                    try {
                      const res = await fetch(`${API}/ee/settings/public-link-prefix`, {
                        method: 'PUT',
                        headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
                        body: JSON.stringify({ prefix: eePublicPrefix }),
                      });
                      const j = await res.json().catch(()=>null);
                      if (!res.ok || !j) throw new Error((j && j.message) || `Failed: ${res.status}`);
                      setEePublicPrefix(String(j.prefix || ''));
                      toast({ title: 'Saved', description: 'Public link prefix updated.' });
                    } catch (e:any) {
                      if (isDemoReadOnlyError(e)) {
                        showDemoReadOnlyToast();
                        return;
                      }
                      setEePrefixError(e?.message || 'Failed to save');
                    } finally { setEePrefixSaving(false); }
                  }}
                  disabled={eePrefixLoading || eePrefixSaving}
                >
                  {eePrefixSaving ? 'Saving…' : 'Save'}
                </Button>
                <Button
                  variant="ghost"
                  onClick={() => {
                    if (isDemoUser) {
                      showDemoReadOnlyToast();
                      return;
                    }
                    setEePublicPrefix('');
                  }}
                  disabled={eePrefixLoading || eePrefixSaving}
                >
                  Clear
                </Button>
              </div>
            </CardContent>
          </Card>
        )}

        {/* Albums Manager */}
        {!isDemoUser ? (
          <AlbumsManager />
        ) : (
          <Card className="mt-8">
            <CardHeader>
              <CardTitle>Albums</CardTitle>
              <CardDescription>Demo account cannot change album settings.</CardDescription>
            </CardHeader>
          </Card>
        )}
        </fieldset>
      </div>

      {/* Album picker modal for selecting parent album */}
      <AlbumPickerDialog
        open={showAlbumPicker}
        albums={albums}
        onClose={() => setShowAlbumPicker(false)}
        onConfirm={(albumId) => {
          setShowAlbumPicker(false);
          setSelectedAlbumId(albumId);
          const a = (albums || []).find(a => a.id === albumId);
          setSelectedAlbumName(a?.name || 'Unknown');
        }}
        initialSelectedId={selectedAlbumId}
        showIncludeSubtree={false}
      />
      {/* Global reindex progress pill is rendered by ReindexProvider */}
    </div>
  );
}
