import { useCallback, useEffect, useRef } from 'react';
import { AppState } from 'react-native';
import { taskExperience, type TaskEvent } from './bridge';

export function useTaskActions(
  conversationId: string | null,
  open: (id: string) => Promise<boolean>,
  cancel: (runId: string) => Promise<void>,
  ready: boolean,
  locale?: string,
) {
  const callbacks = useRef({ open, cancel, ready, locale });
  callbacks.current = { open, cancel, ready, locale };
  const visible = useRef(conversationId);
  visible.current = conversationId;
  const pending = useRef(new Map<string, TaskEvent>());
  const seen = useRef(new Set<string>());
  const flushing = useRef(false);
  const flush = useCallback(async () => {
    if (flushing.current) return;
    flushing.current = true;
    try {
      for (const [key, event] of pending.current) {
        if (
          event.action === 'open' &&
          (!callbacks.current.ready || AppState.currentState !== 'active')
        )
          continue;
        let handled = false;
        try {
          handled =
            event.action === 'cancel'
              ? (await callbacks.current.cancel(event.runId), true)
              : await callbacks.current.open(event.conversationId);
        } catch {
          // One event that throws must not take the rest of the batch with it.
          // It stays pending, so a later flush can carry it.
          continue;
        }
        if (!handled) continue;
        pending.current.delete(key);
        seen.current.add(key);
        if (seen.current.size > 128)
          seen.current.delete(seen.current.values().next().value!);
      }
    } catch {
      /* Keep navigation pending until the existing admission gate opens. */
    } finally {
      flushing.current = false;
    }
  }, []);
  useEffect(() => {
    const receive = (event: TaskEvent) => {
      if (
        !event ||
        !['open', 'cancel'].includes(event.action) ||
        typeof event.runId !== 'string' ||
        typeof event.conversationId !== 'string'
      )
        return;
      const key = `${event.action}:${event.runId}`;
      if (!seen.current.has(key)) pending.current.set(key, event);
      if (pending.current.size > 32)
        pending.current.delete(pending.current.keys().next().value!);
      flush().catch(() => {});
    };
    const drain = () => {
      taskExperience
        .call('visible', {
          locale: callbacks.current.locale,
          conversationId:
            AppState.currentState === 'active' ? visible.current : null,
        })
        .catch(() => {});
      taskExperience
        .call('drain')
        .then(events => {
          if (Array.isArray(events)) events.forEach(receive);
        })
        .catch(() => {});
      flush().catch(() => {});
    };
    const unsubscribe = taskExperience.subscribe(receive);
    const subscription = AppState.addEventListener('change', drain);
    drain();
    return () => {
      unsubscribe();
      subscription.remove();
    };
  }, [flush]);
  useEffect(() => {
    taskExperience
      .call('visible', {
          locale: callbacks.current.locale,
        conversationId:
          AppState.currentState === 'active' ? conversationId : null,
      })
      .catch(() => {});
    flush().catch(() => {});
  }, [conversationId, ready, open, flush, locale]);
}
