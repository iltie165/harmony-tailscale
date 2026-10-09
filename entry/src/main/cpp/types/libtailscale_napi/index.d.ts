export const getVersion: () => string;
export const getStatus: () => string;
export const getLogs: () => string;
export const start: (dataDir: string, hostname: string) => Promise<string>;
export const diagnostics: (dataDir: string) => Promise<string>;
export const close: () => Promise<string>;
