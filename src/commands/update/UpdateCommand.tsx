import { useEffect, useState } from 'react';
import { Box, Text, useApp } from 'ink';
import Spinner from 'ink-spinner';
import { applyUpdate, type ApplyOutcome } from '../../core/updater/applyUpdate.js';

const COLORS: Record<ApplyOutcome['status'], string> = {
  updated: 'green',
  'up-to-date': 'cyan',
  unsupported: 'yellow',
  'no-asset': 'yellow',
  error: 'red',
};

export function UpdateCommand() {
  const { exit } = useApp();
  const [outcome, setOutcome] = useState<ApplyOutcome | null>(null);

  useEffect(() => {
    let active = true;
    applyUpdate().then((o) => {
      if (!active) return;
      setOutcome(o);
      exit();
    });
    return () => {
      active = false;
    };
  }, [exit]);

  if (!outcome) {
    return (
      <Text>
        <Text color="cyan">
          <Spinner type="dots" />
        </Text>{' '}
        Checking for updates…
      </Text>
    );
  }

  return (
    <Box>
      <Text color={COLORS[outcome.status]}>{outcome.message}</Text>
    </Box>
  );
}
