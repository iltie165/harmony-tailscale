declare module 'libtailscale_napi.so' {
  namespace tailscale {
    function getVersion(): string;
    function getStatus(): string;
    function getLogs(): string;
    function start(dataDir: string, hostname: string): Promise<string>;
    function diagnostics(dataDir: string): Promise<string>;
    function close(): Promise<string>;
  }

  export default tailscale;
}
