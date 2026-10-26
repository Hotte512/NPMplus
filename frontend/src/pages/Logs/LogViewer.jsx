import { IconEraser, IconPlayerPause, IconPlayerPlay, IconRefresh, IconSearch } from "@tabler/icons-react";
import { useEffect, useRef, useState } from "react";
import Alert from "react-bootstrap/Alert";
import { useSearchParams } from "react-router";
import { getLog, getLogSince } from "src/api/backend";
import { useProxyHosts } from "src/hooks";
import { intl, T } from "src/locale";

const SOURCES = ["access", "error", "stream", "certbot", "app"];
const HOST_SOURCES = new Set(["access", "error"]);
const LINE_COUNTS = [100, 500, 1000, 5000];
const DEFAULT_LINE_COUNT = 500;
const MAX_DISPLAY_LINES = 5000;
const POLL_INTERVAL = 2000;
const FILTER_DEBOUNCE = 400;

const ACCESS_STATUS = /" (?<status>[1-5]\d\d) \d+ "/u;
const LEVEL_DANGER = /\[(?:error|crit|alert|emerg)\]|:(?:ERROR|CRITICAL):| › (?:error|fatal) /u;
const LEVEL_WARNING = /\[warn\]|:WARNING:| › warn /u;

const lineClassName = (source, entry) => {
	if (entry.marker) return "text-info fst-italic";
	if (source === "access") {
		const status = Number(ACCESS_STATUS.exec(entry.text)?.groups.status);
		if (status >= 500) return "text-danger";
		if (status >= 400) return "text-warning";
		return "";
	}
	if (LEVEL_DANGER.test(entry.text)) return "text-danger";
	if (LEVEL_WARNING.test(entry.text)) return "text-warning";
	return "";
};

const toEntries = (idRef, lines) =>
	lines.map((text) => {
		idRef.current += 1;
		return { id: idRef.current, text };
	});

const parseHostId = (value) => {
	const id = Number.parseInt(value ?? "", 10);
	return Number.isInteger(id) ? Math.max(id, 0) : 0;
};

export default function LogViewer() {
	const [searchParams, setSearchParams] = useSearchParams();
	const [source, setSource] = useState(() =>
		SOURCES.includes(searchParams.get("source")) ? searchParams.get("source") : "access",
	);
	const [hostId, setHostId] = useState(() => parseHostId(searchParams.get("host")));
	const [filterInput, setFilterInput] = useState("");
	const [filter, setFilter] = useState("");
	const [lineCount, setLineCount] = useState(DEFAULT_LINE_COUNT);
	const [live, setLive] = useState(true);
	const [paused, setPaused] = useState(false);
	const [autoScroll, setAutoScroll] = useState(true);
	const [entries, setEntries] = useState([]);
	const [state, setState] = useState({ loading: true, available: true, reason: null, error: null });
	const [pollError, setPollError] = useState(null);
	const [pendingCount, setPendingCount] = useState(0);
	const [reloadKey, setReloadKey] = useState(0);

	const cursorRef = useRef(null);
	const pausedRef = useRef(false);
	const pendingRef = useRef([]);
	const idRef = useRef(0);
	const logRef = useRef(null);

	const { data: proxyHosts } = useProxyHosts();
	const hostParam = HOST_SOURCES.has(source) && hostId ? hostId : undefined;

	const updateUrl = (newSource, newHostId) => {
		const params = { source: newSource };
		if (HOST_SOURCES.has(newSource) && newHostId) params.host = String(newHostId);
		setSearchParams(params, { replace: true });
	};

	const resetPending = () => {
		pendingRef.current = [];
		setPendingCount(0);
	};

	// debounce the text filter
	useEffect(() => {
		const timer = setTimeout(() => setFilter(filterInput.trim()), FILTER_DEBOUNCE);
		return () => clearTimeout(timer);
	}, [filterInput]);

	// initial load, whenever the source or a filter changes
	// biome-ignore lint/correctness/useExhaustiveDependencies: reloadKey is only used to trigger a reload
	useEffect(() => {
		const controller = new AbortController();
		cursorRef.current = null;
		pendingRef.current = [];
		setPendingCount(0);
		setPollError(null);
		setState((prev) => ({ ...prev, loading: true, error: null }));

		getLog(source, { lines: lineCount, host_id: hostParam, filter: filter || undefined }, controller)
			.then((res) => {
				cursorRef.current = res.cursor;
				setEntries(toEntries(idRef, res.lines));
				setState({ loading: false, available: res.available, reason: res.reason ?? null, error: null });
			})
			.catch((err) => {
				if (controller.signal.aborted) return;
				setEntries([]);
				setState({ loading: false, available: true, reason: null, error: err.message });
			});

		return () => controller.abort();
	}, [source, hostParam, filter, lineCount, reloadKey]);

	// live tail: poll for new lines after the cursor
	useEffect(() => {
		if (!live || state.loading || state.error || !state.available) return;

		const controller = new AbortController();
		let inFlight = false;

		const poll = async () => {
			if (inFlight || !cursorRef.current) return;
			inFlight = true;
			try {
				const res = await getLogSince(
					source,
					{ cursor: cursorRef.current, host_id: hostParam, filter: filter || undefined },
					controller,
				);
				setPollError(null);
				if (!res.available) {
					setState({ loading: false, available: false, reason: res.reason ?? null, error: null });
					return;
				}
				cursorRef.current = res.cursor;
				const added = toEntries(idRef, res.lines);
				if (res.reset) {
					idRef.current += 1;
					added.unshift({
						id: idRef.current,
						text: intl.formatMessage({ id: "logs.rotated" }),
						marker: true,
					});
				}
				if (!added.length) return;
				if (pausedRef.current) {
					pendingRef.current = [...pendingRef.current, ...added].slice(-MAX_DISPLAY_LINES);
					setPendingCount(pendingRef.current.length);
				} else {
					setEntries((prev) => [...prev, ...added].slice(-MAX_DISPLAY_LINES));
				}
			} catch (err) {
				if (!controller.signal.aborted) setPollError(err.message);
			} finally {
				inFlight = false;
			}
		};

		const timer = setInterval(poll, POLL_INTERVAL);
		return () => {
			clearInterval(timer);
			controller.abort();
		};
	}, [live, source, hostParam, filter, state.loading, state.error, state.available]);

	// keep the newest line visible
	useEffect(() => {
		if (!(autoScroll && entries.length && logRef.current)) return;
		logRef.current.scrollTop = logRef.current.scrollHeight;
	}, [entries, autoScroll]);

	const setPausedState = (value) => {
		pausedRef.current = value;
		setPaused(value);
		if (!value && pendingRef.current.length) {
			const pending = pendingRef.current;
			setEntries((prev) => [...prev, ...pending].slice(-MAX_DISPLAY_LINES));
			resetPending();
		}
	};

	const sortedHosts = [...(proxyHosts ?? [])].sort((a, b) =>
		(a.domainNames[0] ?? "").localeCompare(b.domainNames[0] ?? ""),
	);

	return (
		<div className="card mt-4">
			<div className="card-status-top bg-cyan" />
			<div className="card-header">
				<div className="row w-full g-2 align-items-center">
					<div className="col-auto">
						<h2 className="mt-1 mb-0">
							<T id="logs" />
						</h2>
					</div>
					<div className="col-md col-sm-12">
						<div className="d-flex flex-wrap gap-2 justify-content-md-end align-items-center">
							<select
								className="form-select form-select-sm w-auto"
								aria-label={intl.formatMessage({ id: "logs.source" })}
								value={source}
								onChange={(e) => {
									setSource(e.target.value);
									updateUrl(e.target.value, hostId);
								}}
							>
								{SOURCES.map((item) => (
									<option key={item} value={item}>
										{intl.formatMessage({ id: `logs.source.${item}` })}
									</option>
								))}
							</select>
							{HOST_SOURCES.has(source) && (
								<select
									className="form-select form-select-sm w-auto"
									aria-label={intl.formatMessage({ id: "proxy-host" })}
									value={hostId}
									onChange={(e) => {
										const id = parseHostId(e.target.value);
										setHostId(id);
										updateUrl(source, id);
									}}
								>
									<option value={0}>{intl.formatMessage({ id: "logs.host.all" })}</option>
									{sortedHosts.map((host) => (
										<option key={host.id} value={host.id}>
											{host.domainNames.join(", ")}
										</option>
									))}
									{hostId > 0 && !sortedHosts.some((host) => host.id === hostId) && (
										<option value={hostId}>#{hostId}</option>
									)}
								</select>
							)}
							<div className="input-group input-group-flat w-auto">
								<span className="input-group-text input-group-text-sm">
									<IconSearch size={16} />
								</span>
								<input
									type="text"
									className="form-control form-control-sm"
									autoComplete="off"
									maxLength={255}
									placeholder={intl.formatMessage({ id: "logs.search-placeholder" })}
									value={filterInput}
									onChange={(e) => setFilterInput(e.target.value)}
								/>
							</div>
							<select
								className="form-select form-select-sm w-auto"
								aria-label={intl.formatMessage({ id: "logs.lines" })}
								value={lineCount}
								onChange={(e) => setLineCount(Number(e.target.value))}
							>
								{LINE_COUNTS.map((count) => (
									<option key={count} value={count}>
										{count} {intl.formatMessage({ id: "logs.lines" })}
									</option>
								))}
							</select>
							<label className="form-check form-switch mb-0">
								<input
									className="form-check-input"
									type="checkbox"
									checked={live}
									onChange={(e) => {
										setLive(e.target.checked);
										if (!e.target.checked) setPausedState(false);
									}}
								/>
								<span className="form-check-label">
									<T id="logs.live" />
								</span>
							</label>
							<label className="form-check form-switch mb-0">
								<input
									className="form-check-input"
									type="checkbox"
									checked={autoScroll}
									onChange={(e) => setAutoScroll(e.target.checked)}
								/>
								<span className="form-check-label">
									<T id="logs.autoscroll" />
								</span>
							</label>
							{live && (
								<button type="button" className="btn btn-sm" onClick={() => setPausedState(!paused)}>
									{paused ? <IconPlayerPlay size={16} /> : <IconPlayerPause size={16} />}
									<T id={paused ? "logs.resume" : "logs.pause"} />
									{paused && pendingCount > 0 && (
										<span className="badge bg-cyan-lt ms-1">{pendingCount}</span>
									)}
								</button>
							)}
							<button
								type="button"
								className="btn btn-sm"
								onClick={() => {
									setEntries([]);
									resetPending();
								}}
							>
								<IconEraser size={16} />
								<T id="action.clear" />
							</button>
							<button type="button" className="btn btn-sm" onClick={() => setReloadKey((key) => key + 1)}>
								<IconRefresh size={16} />
								<T id="logs.refresh" />
							</button>
						</div>
					</div>
				</div>
			</div>
			<div className="card-body">
				{state.error && <Alert variant="danger">{state.error}</Alert>}
				{pollError && <Alert variant="warning">{pollError}</Alert>}
				{!state.available && (
					<Alert variant="warning">
						<T id={`logs.${state.reason ?? "not-found"}`} />
					</Alert>
				)}
				{entries.length >= MAX_DISPLAY_LINES && (
					<p className="text-secondary small mb-2">
						<T id="logs.truncated-warning" />
					</p>
				)}
				{state.available && !state.error && (
					<pre
						ref={logRef}
						className="m-0 p-3"
						style={{
							height: "70vh",
							minHeight: "300px",
							overflow: "auto",
							whiteSpace: "pre-wrap",
							wordBreak: "break-all",
							fontSize: "0.8rem",
							opacity: state.loading ? 0.6 : 1,
						}}
					>
						{entries.length === 0 && !state.loading ? (
							<span className="text-secondary">
								<T id="logs.empty" />
							</span>
						) : (
							entries.map((entry) => (
								<div key={entry.id} className={lineClassName(source, entry)}>
									{entry.text}
								</div>
							))
						)}
					</pre>
				)}
			</div>
		</div>
	);
}
