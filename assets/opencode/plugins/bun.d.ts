declare module "bun:sqlite" {
  export class Database {
    constructor(filename: string, options?: { readonly?: boolean; create?: boolean; readwrite?: boolean });
    exec(sql: string): void;
    query<T = unknown, P extends any[] = any[]>(sql: string): {
      get(...params: P): T | null;
      all(...params: P): T[];
      run(...params: P): void;
    };
    close(): void;
  }
}

declare module "bun:test" {
  export const describe: any;
  export const it: any;
  export const expect: any;
  export const beforeEach: any;
}
