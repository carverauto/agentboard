package cli

// `admin rollout` and shared target-file pin converge (GH #138). Rollout
// order is fixed: pre-migration backup -> migration Job on the same digest
// -> roll -> verify (rollout status, readiness, meta schema, smoke read,
// soak) -> automatic rollback to the previous pin on failure. Digest pins
// only; tags are rejected at the gate.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/spf13/cobra"
)

var digestRef = regexp.MustCompile(`^([^@\s]+)@sha256:[0-9a-f]{64}$`)

var bareDigestRef = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

type kubeRunner struct {
	bin       string
	context   string
	namespace string
	log       []string // argv log for tests
}

func lookRunner(bin string) (kubeRunner, error) {
	path, err := exec.LookPath(bin)
	if err != nil {
		return kubeRunner{}, errors.New(bin + " not found on PATH; install kubectl (or docker for compose targets)")
	}
	return kubeRunner{bin: path}, nil
}

func (k *kubeRunner) baseArgs() []string {
	args := []string{}
	if k.context != "" {
		args = append(args, "--context", k.context)
	}
	if k.namespace != "" {
		args = append(args, "-n", k.namespace)
	}
	return args
}

func (k *kubeRunner) run(ctx context.Context, stdin string, timeout time.Duration, args ...string) (string, error) {
	full := append(append([]string{}, k.baseArgs()...), args...)
	k.log = append(k.log, k.bin+" "+strings.Join(full, " "))
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, k.bin, full...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), errors.New(k.bin + " " + strings.Join(args, " ") + " failed: " + strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// setOverlayDigest converges the `digest:` pin for image name in a
// kustomization.yaml, removing any `newTag:` in the same entry. It returns
// the previous pin ("" when none) and whether the file changed.
func setOverlayDigest(lines []string, image, digest string) ([]string, string, bool, error) {
	entry := -1
	prev := ""
	end := len(lines)
	for i, l := range lines {
		t := strings.TrimSpace(l)
		if strings.HasPrefix(t, "- name:") && strings.TrimSpace(strings.TrimPrefix(t, "- name:")) == image {
			entry = i
			continue
		}
		if entry >= 0 {
			// Entry ends at the next list item or block end (dedent to 2sp).
			if strings.HasPrefix(l, "  - ") || (len(l) > 0 && l[0] != ' ' && strings.TrimSpace(l) != "" && !strings.HasPrefix(l, "#")) {
				end = i
				break
			}
			if strings.HasPrefix(t, "digest:") {
				prev = strings.TrimSpace(strings.TrimPrefix(t, "digest:"))
			}
		}
	}
	if entry < 0 {
		return nil, "", false, errors.New("overlay has no images entry for " + image)
	}
	if prev == digest {
		return lines, prev, false, nil
	}
	out := append([]string{}, lines...)
	// Drop newTag inside the entry; kustomize digest replaces tag.
	filtered := out[:entry+1]
	digestIdx := -1
	for i := entry + 1; i < end && i < len(out); i++ {
		t := strings.TrimSpace(out[i])
		if strings.HasPrefix(t, "newTag:") {
			continue
		}
		if strings.HasPrefix(t, "digest:") {
			digestIdx = len(filtered)
		}
		filtered = append(filtered, out[i])
	}
	filtered = append(filtered, out[end:]...)
	out = filtered
	if digestIdx >= 0 {
		indent := out[digestIdx][:len(out[digestIdx])-len(strings.TrimLeft(out[digestIdx], " "))]
		out[digestIdx] = indent + "digest: " + digest
	} else {
		ins := append([]string{}, out[:entry+1]...)
		ins = append(ins, "    digest: "+digest)
		ins = append(ins, out[entry+1:]...)
		out = ins
	}
	return out, prev, true, nil
}

// setComposeImage converges `image:` refs whose repo matches image to the
// digest pin. It returns the previous ref and whether anything changed.
func setComposeImage(lines []string, image, pin string) ([]string, string, bool, error) {
	changed := false
	prev := ""
	out := append([]string{}, lines...)
	found := false
	for i, l := range out {
		t := strings.TrimSpace(l)
		if !strings.HasPrefix(t, "image:") {
			continue
		}
		ref := strings.TrimSpace(strings.TrimPrefix(t, "image:"))
		ref = strings.Trim(ref, `"'`)
		repo := ref
		if k := strings.Index(repo, "@"); k >= 0 {
			repo = repo[:k]
		}
		if k := strings.LastIndex(repo, ":"); k >= 0 && !strings.Contains(repo[k:], "/") {
			repo = repo[:k]
		}
		if repo != image {
			continue
		}
		found = true
		if ref == pin {
			continue
		}
		prev = ref
		indent := l[:len(l)-len(strings.TrimLeft(l, " "))]
		out[i] = indent + "image: " + pin
		changed = true
	}
	if !found {
		return nil, "", false, errors.New("compose file has no image for " + image)
	}
	return out, prev, changed, nil
}

type rolloutFlags struct {
	overlay       string
	compose       string
	direct        bool
	image         string
	deployment    string
	container     string
	context       string
	namespace     string
	migrationJob  string
	migrationName string
	cnpgCluster   string
	backupPath    string
	dbName        string
	soakSeconds   int
	timeoutSecs   int
	recordOut     string
	force         bool
	dryRun        bool
}

func (c *commands) adminRollout() *cobra.Command {
	f := rolloutFlags{}
	cmd := &cobra.Command{Use: "rollout IMAGE@sha256:DIGEST", Short: "Backup -> migrate -> roll -> verify -> auto-rollback", Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		return c.runRollout(cmd, args[0], f)
	}}
	cmd.Flags().StringVar(&f.overlay, "overlay", "", "Kustomize overlay kustomization.yaml path")
	cmd.Flags().StringVar(&f.compose, "compose", "", "Docker compose file path")
	cmd.Flags().BoolVar(&f.direct, "direct", false, "Apply directly with kubectl instead of a file target")
	cmd.Flags().StringVar(&f.image, "image", "", "Image repo for the overlay/compose entry (required with --overlay/--compose)")
	cmd.Flags().StringVar(&f.deployment, "deployment", "", "Deployment name for status/verify/rollback")
	cmd.Flags().StringVar(&f.container, "container", "", "Container name (required with --direct)")
	cmd.Flags().StringVar(&f.context, "context", "", "kubectl context")
	cmd.Flags().StringVar(&f.namespace, "namespace", "", "Kubernetes namespace")
	cmd.Flags().StringVar(&f.migrationJob, "migration-job", "", "Migration Job manifest path (image rewritten to the digest)")
	cmd.Flags().StringVar(&f.migrationName, "migration-job-name", "", "Migration Job name to wait for")
	cmd.Flags().StringVar(&f.cnpgCluster, "cnpg-cluster", "", "CNPG cluster name for an on-demand Backup")
	cmd.Flags().StringVar(&f.backupPath, "backup-path", "", "Logical dump destination (pg_dump -f); alternative to --cnpg-cluster")
	cmd.Flags().StringVar(&f.dbName, "db-name", "", "Database for --backup-path pg_dump (defaults to $PGDATABASE)")
	cmd.Flags().IntVar(&f.soakSeconds, "soak-seconds", 300, "Post-verify soak window in seconds (0 skips)")
	cmd.Flags().IntVar(&f.timeoutSecs, "timeout-seconds", 600, "kubectl wait timeout in seconds")
	cmd.Flags().StringVar(&f.recordOut, "record-out", "", "Write the machine-readable rollout record here")
	cmd.Flags().BoolVar(&f.force, "force", false, "Overwrite an existing --record-out file")
	cmd.Flags().BoolVar(&f.dryRun, "dry-run", false, "Show the diff without writing anything")
	cmd.Flags().BoolVar(&f.dryRun, "plan", false, "Alias for --dry-run")
	return cmd
}

func (c *commands) runRollout(cmd *cobra.Command, pin string, f rolloutFlags) error {
	name := "admin rollout"
	m := digestRef.FindStringSubmatch(pin)
	if m == nil {
		return errors.New("rollout pins must be immutable digests IMAGE@sha256:<64 hex>; tags are rejected")
	}
	digest := "sha256:" + pin[strings.LastIndex(pin, ":")+1:]
	targets := 0
	if f.overlay != "" {
		targets++
	}
	if f.compose != "" {
		targets++
	}
	if f.direct {
		targets++
	}
	if targets != 1 {
		return errors.New("exactly one target is required: --overlay, --compose, or --direct")
	}
	if (f.cnpgCluster == "") == (f.backupPath == "") {
		return errors.New("exactly one backup mode is required: --cnpg-cluster or --backup-path")
	}
	if f.compose != "" && (f.migrationJob != "" || f.cnpgCluster != "") {
		return errors.New("compose targets support --backup-path file edits plus up/verify only; migration Jobs and CNPG backups are kubectl paths")
	}
	if !f.direct && f.image == "" {
		return errors.New("--image is required with file targets")
	}
	if f.direct && f.container == "" {
		return errors.New("--container is required with --direct")
	}
	if f.deployment == "" {
		return errors.New("--deployment is required")
	}
	if f.namespace == "" {
		return errors.New("--namespace is required")
	}
	if (f.overlay != "" || f.direct) && f.migrationJob == "" {
		return errors.New("--migration-job is required for kubectl targets")
	}
	if f.soakSeconds < 0 || f.timeoutSecs <= 0 {
		return errors.New("--soak-seconds must be >= 0 and --timeout-seconds positive")
	}

	// currentRef is always a full IMAGE@digest ref (or "" when unset) so
	// file pins compare exactly against the requested pin.
	currentRef := ""
	previous := ""
	if f.overlay != "" {
		lines, err := readTargetLines(f.overlay)
		if err != nil {
			return err
		}
		_, prev, _, err := setOverlayDigest(lines, f.image, digest)
		if err != nil {
			return err
		}
		previous = prev
		if prev != "" {
			currentRef = f.image + "@" + prev
		}
	} else if f.compose != "" {
		lines, err := readTargetLines(f.compose)
		if err != nil {
			return err
		}
		_, prev, _, err := setComposeImage(lines, f.image, pin)
		if err != nil {
			return err
		}
		previous = prev
		currentRef = prev
	} else {
		k, err := lookRunner("kubectl")
		if err != nil {
			return err
		}
		k.context, k.namespace = f.context, f.namespace
		out, err := k.run(cmd.Context(), "", 60*time.Second, "get", "deployment/"+f.deployment, "-o", "jsonpath={.spec.template.spec.containers[*].image}")
		if err != nil {
			return &adminExit{code: 1, msg: name + ": live pin read failed: " + err.Error()}
		}
		previous = strings.TrimSpace(out)
		if len(strings.Fields(previous)) != 1 {
			return errors.New("live deployment has multiple container images; --direct requires exactly one")
		}
		currentRef = previous
	}
	diff := []adminDiff{}
	if currentRef != pin {
		diff = append(diff, adminDiff{Scope: "pin", Field: f.deployment, Current: currentRef, Desired: pin})
	}
	record := map[string]any{
		"verified_at": time.Now().UTC().Format(time.RFC3339),
		"image":       pin,
		"target":      rolloutTargetName(f),
		"steps":       []string{},
	}
	noteStep := func(s string) {
		record["steps"] = append(record["steps"].([]string), s)
	}
	if f.dryRun {
		if err := c.adminReport(cmd, name, true, diff, record); err != nil {
			return err
		}
		if len(diff) > 0 {
			return adminPending(name, len(diff))
		}
		return nil
	}
	if len(diff) == 0 {
		record["previous_image"] = previous
		if err := c.adminReport(cmd, name, false, nil, record); err != nil {
			return err
		}
		return c.writeRecord(f, record)
	}
	record["previous_image"] = previous
	timeout := time.Duration(f.timeoutSecs) * time.Second

	// Step 1: pre-migration backup, before any migration.
	backupRef := ""
	if f.cnpgCluster != "" {
		k, err := lookRunner("kubectl")
		if err != nil {
			return err
		}
		k.context, k.namespace = f.context, f.namespace
		bname := fmt.Sprintf("agentboard-manual-%d", time.Now().Unix())
		manifest := "apiVersion: postgresql.cnpg.io/v1\nkind: Backup\nmetadata:\n  name: " + bname + "\nspec:\n  cluster:\n    name: " + f.cnpgCluster + "\n"
		if _, err := k.run(cmd.Context(), manifest, timeout, "apply", "-f", "-"); err != nil {
			return &adminExit{code: 1, msg: name + ": backup apply failed: " + err.Error()}
		}
		if _, err := k.run(cmd.Context(), "", timeout, "wait", "--for=jsonpath={.status.phase}=Completed", "backup/"+bname, "--timeout", strconv.Itoa(f.timeoutSecs)+"s"); err != nil {
			return &adminExit{code: 1, msg: name + ": backup did not complete: " + err.Error()}
		}
		backupRef = "cnpg-backup/" + bname
		noteStep("backup:" + backupRef)
	} else {
		dbName := f.dbName
		if dbName == "" {
			dbName = os.Getenv("PGDATABASE")
		}
		if dbName == "" {
			return errors.New("--db-name or $PGDATABASE is required for --backup-path")
		}
		pg, err := exec.LookPath("pg_dump")
		if err != nil {
			return errors.New("pg_dump not found on PATH")
		}
		cctx, cancel := context.WithTimeout(cmd.Context(), timeout)
		defer cancel()
		dump := exec.CommandContext(cctx, pg, "-f", f.backupPath, dbName)
		if out, err := dump.CombinedOutput(); err != nil {
			return &adminExit{code: 1, msg: name + ": logical backup failed: " + strings.TrimSpace(string(out))}
		}
		backupRef = "pg_dump:" + f.backupPath
		noteStep("backup:" + backupRef)
		record["backup_database"] = dbName
	}
	record["pre_migration_backup"] = backupRef

	rollback := func(cause string) error {
		rb := c.rollbackPin(cmd.Context(), f, previous)
		record["rollback_performed"] = rb == nil
		record["rollback_error"] = ""
		if rb != nil {
			record["rollback_error"] = rb.Error()
		}
		_ = c.writeRecord(f, record)
		if rb != nil {
			return &adminExit{code: 1, msg: name + ": " + cause + "; rollback also failed: " + rb.Error()}
		}
		return &adminExit{code: 3, msg: name + ": " + cause + "; rolled back to " + previous}
	}

	// Step 2: migration Job on the SAME digest.
	if f.migrationJob != "" {
		k, err := lookRunner("kubectl")
		if err != nil {
			return rollback("kubectl not found for migration: " + err.Error())
		}
		k.context, k.namespace = f.context, f.namespace
		raw, err := os.ReadFile(f.migrationJob)
		if err != nil {
			return rollback("cannot read migration manifest: " + err.Error())
		}
		jobName := f.migrationName
		if jobName == "" {
			jobName, err = manifestName(string(raw))
			if err != nil {
				return rollback("migration manifest has no metadata.name: " + err.Error())
			}
		}
		rewritten, err := rewriteManifestImage(string(raw), pin)
		if err != nil {
			return rollback("migration manifest has no image field: " + err.Error())
		}
		if _, err := k.run(cmd.Context(), rewritten, timeout, "apply", "-f", "-"); err != nil {
			return rollback("migration apply failed: " + err.Error())
		}
		if _, err := k.run(cmd.Context(), "", timeout, "wait", "--for=condition=complete", "job/"+jobName, "--timeout", strconv.Itoa(f.timeoutSecs)+"s"); err != nil {
			return rollback("migration job did not complete: " + err.Error())
		}
		record["migration"] = map[string]any{"job": jobName, "image": pin}
		noteStep("migration:" + jobName)
	}

	// Step 3: roll.
	if f.overlay != "" {
		lines, _ := readTargetLines(f.overlay)
		updated, _, changed, err := setOverlayDigest(lines, f.image, digest)
		if err != nil {
			return rollback(err.Error())
		}
		if changed {
			if err := writeTargetLines(f.overlay, updated); err != nil {
				return rollback("overlay write failed: " + err.Error())
			}
		}
		k, _ := lookRunner("kubectl")
		k.context, k.namespace = f.context, f.namespace
		dir := f.overlay
		if i := strings.LastIndex(dir, "/"); i >= 0 {
			dir = dir[:i]
		}
		if _, err := k.run(cmd.Context(), "", timeout, "apply", "-k", dir); err != nil {
			return rollback("overlay apply failed: " + err.Error())
		}
		noteStep("roll:overlay")
	} else if f.compose != "" {
		lines, _ := readTargetLines(f.compose)
		updated, _, changed, err := setComposeImage(lines, f.image, pin)
		if err != nil {
			return rollback(err.Error())
		}
		if changed {
			if err := writeTargetLines(f.compose, updated); err != nil {
				return rollback("compose write failed: " + err.Error())
			}
		}
		dc, err := exec.LookPath("docker")
		if err != nil {
			return rollback("docker not found on PATH")
		}
		cctx, cancel := context.WithTimeout(cmd.Context(), timeout)
		defer cancel()
		if out, err := exec.CommandContext(cctx, dc, "compose", "-f", f.compose, "up", "-d").CombinedOutput(); err != nil {
			return rollback("compose up failed: " + strings.TrimSpace(string(out)))
		}
		noteStep("roll:compose")
	} else {
		k, _ := lookRunner("kubectl")
		k.context, k.namespace = f.context, f.namespace
		if _, err := k.run(cmd.Context(), "", timeout, "set", "image", "deployment/"+f.deployment, f.container+"="+pin); err != nil {
			return rollback("set image failed: " + err.Error())
		}
		noteStep("roll:direct")
	}

	// Step 4: verify.
	if f.overlay != "" || f.direct {
		k, _ := lookRunner("kubectl")
		k.context, k.namespace = f.context, f.namespace
		if _, err := k.run(cmd.Context(), "", timeout, "rollout", "status", "deployment/"+f.deployment, "--timeout", strconv.Itoa(f.timeoutSecs)+"s"); err != nil {
			return rollback("rollout status failed: " + err.Error())
		}
		if _, err := k.run(cmd.Context(), "", timeout, "wait", "--for=condition=available", "deployment/"+f.deployment, "--timeout", strconv.Itoa(f.timeoutSecs)+"s"); err != nil {
			return rollback("deployment not available: " + err.Error())
		}
		noteStep("verify:rollout-ready")
	}
	api, err := client.New(c.cfg)
	if err != nil {
		return rollback("board client failed: " + err.Error())
	}
	defer api.Close()
	raw, err := api.JSON(cmd.Context(), http.MethodGet, "meta", nil, nil)
	if err != nil {
		return rollback("meta verify failed: " + err.Error())
	}
	var meta struct {
		API    int `json:"api_version"`
		Schema int `json:"schema_version"`
	}
	if json.Unmarshal(raw, &meta) != nil || meta.API != 1 {
		return rollback("meta verify failed: incompatible API")
	}
	record["schema"] = meta.Schema
	if _, err := api.JSON(cmd.Context(), http.MethodGet, "agents", url.Values{"limit": {"1"}}, nil); err != nil {
		return rollback("smoke read failed: " + err.Error())
	}
	noteStep("verify:meta-smoke")
	if f.soakSeconds > 0 {
		select {
		case <-cmd.Context().Done():
			return rollback("soak interrupted")
		case <-time.After(time.Duration(f.soakSeconds) * time.Second):
		}
		noteStep("verify:soak")
	}
	record["rollback_performed"] = false
	if err := c.adminReport(cmd, name, false, diff, record); err != nil {
		return err
	}
	return c.writeRecord(f, record)
}

func rolloutTargetName(f rolloutFlags) string {
	if f.overlay != "" {
		return "kustomize:" + f.overlay
	}
	if f.compose != "" {
		return "compose:" + f.compose
	}
	return "direct:" + f.deployment
}

func (c *commands) rollbackPin(ctx context.Context, f rolloutFlags, prev string) error {
	if prev == "" {
		return errors.New("no previous pin to restore")
	}
	timeout := time.Duration(f.timeoutSecs) * time.Second
	if f.overlay != "" {
		lines, err := readTargetLines(f.overlay)
		if err != nil {
			return err
		}
		// Overlay pins are stored as bare digests; a full IMAGE@digest
		// ref is accepted defensively.
		restore := prev
		if m := digestRef.FindStringSubmatch(prev); m != nil {
			restore = "sha256:" + prev[strings.LastIndex(prev, ":")+1:]
		}
		if !bareDigestRef.MatchString(restore) {
			return errors.New("previous pin is not a digest; cannot restore")
		}
		updated, _, _, err := setOverlayDigest(lines, f.image, restore)
		if err != nil {
			return err
		}
		if err := writeTargetLines(f.overlay, updated); err != nil {
			return err
		}
		k, err := lookRunner("kubectl")
		if err != nil {
			return err
		}
		k.context, k.namespace = f.context, f.namespace
		dir := f.overlay
		if i := strings.LastIndex(dir, "/"); i >= 0 {
			dir = dir[:i]
		}
		_, err = k.run(ctx, "", timeout, "apply", "-k", dir)
		return err
	}
	if f.compose != "" {
		lines, err := readTargetLines(f.compose)
		if err != nil {
			return err
		}
		updated, _, _, err := setComposeImage(lines, f.image, prev)
		if err != nil {
			return err
		}
		if err := writeTargetLines(f.compose, updated); err != nil {
			return err
		}
		dc, err := exec.LookPath("docker")
		if err != nil {
			return err
		}
		cctx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		out, err := exec.CommandContext(cctx, dc, "compose", "-f", f.compose, "up", "-d").CombinedOutput()
		if err != nil {
			return errors.New(strings.TrimSpace(string(out)))
		}
		return nil
	}
	k, err := lookRunner("kubectl")
	if err != nil {
		return err
	}
	k.context, k.namespace = f.context, f.namespace
	_, err = k.run(ctx, "", timeout, "set", "image", "deployment/"+f.deployment, f.container+"="+prev)
	return err
}

func (c *commands) writeRecord(f rolloutFlags, record map[string]any) error {
	if f.recordOut == "" {
		return nil
	}
	if _, err := os.Lstat(f.recordOut); err == nil && !f.force {
		return errors.New("record file exists; pass --force to overwrite")
	} else if err != nil && !os.IsNotExist(err) {
		return errors.New("cannot inspect record output path")
	}
	raw, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(f.recordOut, append(raw, '\n'), 0644)
}

// manifestName extracts metadata.name from a minimal manifest.
func manifestName(raw string) (string, error) {
	inMeta := false
	for _, l := range strings.Split(raw, "\n") {
		t := strings.TrimSpace(l)
		if t == "metadata:" {
			inMeta = true
			continue
		}
		if inMeta {
			if strings.HasPrefix(t, "name:") {
				n := strings.TrimSpace(strings.TrimPrefix(t, "name:"))
				if n != "" {
					return n, nil
				}
			}
			if t != "" && !strings.HasPrefix(l, " ") && !strings.HasPrefix(l, "\t") {
				break
			}
		}
	}
	return "", errors.New("no metadata.name found")
}

func manifestImageRepo(ref string) string {
	ref = strings.Trim(ref, `"'`)
	repo := ref
	if k := strings.Index(repo, "@"); k >= 0 {
		repo = repo[:k]
	}
	if k := strings.LastIndex(repo, ":"); k >= 0 && !strings.Contains(repo[k:], "/") {
		repo = repo[:k]
	}
	return repo
}

// rewriteManifestImage replaces every `image:` value whose repo matches the
// rollout pin repo with pin.
func rewriteManifestImage(raw, pin string) (string, error) {
	target := pin
	if k := strings.Index(pin, "@"); k >= 0 {
		target = pin[:k]
	}
	target = manifestImageRepo(target)
	lines := strings.Split(raw, "\n")
	matched := false
	for i, l := range lines {
		t := strings.TrimSpace(l)
		if !strings.HasPrefix(t, "image:") {
			continue
		}
		ref := strings.TrimSpace(strings.TrimPrefix(t, "image:"))
		if manifestImageRepo(ref) != target {
			continue
		}
		indent := l[:len(l)-len(strings.TrimLeft(l, " "))]
		lines[i] = indent + "image: " + pin
		matched = true
	}
	if !matched {
		return "", errors.New("migration manifest has no image for " + target)
	}
	return strings.Join(lines, "\n"), nil
}
