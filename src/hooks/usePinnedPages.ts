import { useState, useCallback, useEffect } from 'react';

export interface PinnedPage {
  href: string;
  name: string;
  icon: string; // lucide icon name stored as string
}

const MAX_PINS = 8;

function getStorageKey(userId: string) {
  return `flowwink-pinned-${userId}`;
}

// Cross-instance pub/sub so every <usePinnedPages> hook (sidebar, header, …)
// stays in sync without a page refresh — and across browser tabs via the
// native `storage` event.
type Listener = (pins: PinnedPage[]) => void;
const listeners = new Map<string, Set<Listener>>();

function subscribe(userId: string, fn: Listener) {
  let set = listeners.get(userId);
  if (!set) {
    set = new Set();
    listeners.set(userId, set);
  }
  set.add(fn);
  return () => {
    set!.delete(fn);
  };
}

function broadcast(userId: string, pins: PinnedPage[]) {
  listeners.get(userId)?.forEach((fn) => fn(pins));
}

function readFromStorage(userId: string): PinnedPage[] {
  try {
    const stored = localStorage.getItem(getStorageKey(userId));
    return stored ? (JSON.parse(stored) as PinnedPage[]) : [];
  } catch {
    return [];
  }
}

export function usePinnedPages(userId: string | undefined) {
  const [pins, setPins] = useState<PinnedPage[]>(() =>
    userId ? readFromStorage(userId) : [],
  );

  // Hydrate + subscribe to in-app + cross-tab updates.
  useEffect(() => {
    if (!userId) {
      setPins([]);
      return;
    }
    setPins(readFromStorage(userId));

    const unsub = subscribe(userId, setPins);

    const onStorage = (e: StorageEvent) => {
      if (e.key === getStorageKey(userId)) {
        setPins(readFromStorage(userId));
      }
    };
    window.addEventListener('storage', onStorage);

    return () => {
      unsub();
      window.removeEventListener('storage', onStorage);
    };
  }, [userId]);

  const persist = useCallback(
    (next: PinnedPage[]) => {
      if (!userId) return;
      localStorage.setItem(getStorageKey(userId), JSON.stringify(next));
      broadcast(userId, next);
    },
    [userId],
  );

  const addPin = useCallback(
    (page: PinnedPage) => {
      if (!userId) return;
      const prev = readFromStorage(userId);
      if (prev.length >= MAX_PINS) return;
      if (prev.some((p) => p.href === page.href)) return;
      persist([...prev, page]);
    },
    [persist, userId],
  );

  const removePin = useCallback(
    (href: string) => {
      if (!userId) return;
      const prev = readFromStorage(userId);
      persist(prev.filter((p) => p.href !== href));
    },
    [persist, userId],
  );

  const isPinned = useCallback(
    (href: string) => pins.some((p) => p.href === href),
    [pins],
  );

  return { pins, addPin, removePin, isPinned };
}
