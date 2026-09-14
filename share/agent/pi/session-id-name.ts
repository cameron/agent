import { closeSync, openSync, readSync } from "node:fs";

const delimiter = " · ";

export function composeSessionName(
	currentName: string | undefined,
	currentId: string,
	previousId?: string,
): string {
	if (currentName && (currentName === currentId || currentName.endsWith(`${delimiter}${currentId}`))) {
		return currentName;
	}

	if (previousId) {
		if (currentName === previousId) return currentId;
		if (currentName?.endsWith(`${delimiter}${previousId}`)) {
			const customName = currentName.slice(0, -`${delimiter}${previousId}`.length);
			return customName ? `${customName}${delimiter}${currentId}` : currentId;
		}
	}

	return currentName ? `${currentName}${delimiter}${currentId}` : currentId;
}

export function readSessionId(sessionFile: string | undefined): string | undefined {
	if (!sessionFile) return undefined;

	let descriptor: number | undefined;
	try {
		descriptor = openSync(sessionFile, "r");
		const buffer = Buffer.alloc(65536);
		const length = readSync(descriptor, buffer, 0, buffer.length, 0);
		const firstLine = buffer.subarray(0, length).toString("utf8").split(/\r?\n/, 1)[0];
		const header = JSON.parse(firstLine);
		return header?.type === "session" && typeof header.id === "string"
			? header.id
			: undefined;
	} catch {
		return undefined;
	} finally {
		if (descriptor !== undefined) {
			try {
				closeSync(descriptor);
			} catch {
				// The ID display is best-effort if the inherited session file changes.
			}
		}
	}
}

export default function sessionIdName(pi: {
	on: (event: "session_start", handler: (event: any, ctx: any) => void) => void;
	getSessionName: () => string | undefined;
	setSessionName: (name: string) => void;
}) {
	pi.on("session_start", (event, ctx) => {
		const currentId = ctx.sessionManager.getSessionId();
		const currentName = pi.getSessionName();
		const previousSessionFile = event.reason === "fork"
			? event.previousSessionFile
			: undefined;
		const previousId = readSessionId(previousSessionFile);
		const composedName = composeSessionName(currentName, currentId, previousId);

		if (composedName !== currentName) pi.setSessionName(composedName);
	});
}
