package cli

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	payload "github.com/carverauto/agentboard"
	"github.com/spf13/cobra"
)

func (c *commands) skills() *cobra.Command {
	cmd := &cobra.Command{Use: "skills", Short: "Install bundled Agentboard workflows (no hooks or API access)"}
	var destination string
	install := &cobra.Command{Use: "install", Short: "Install all bundled skills into ~/.agents/skills", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			if destination == "" {
				destination = filepath.Join(home, ".agents", "skills")
			}
			data := os.Getenv("XDG_DATA_HOME")
			if data == "" {
				data = filepath.Join(home, ".local", "share")
			}
			if !filepath.IsAbs(data) {
				return errors.New("XDG_DATA_HOME must be an absolute path")
			}
			result, err := installSkills(destination, filepath.Join(data, "agentboard", "skill-bundles"))
			if err != nil {
				return err
			}
			if c.json {
				return json.NewEncoder(cmd.OutOrStdout()).Encode(result)
			}
			_, err = fmt.Fprintf(cmd.OutOrStdout(), "Installed %d Agentboard skills in %s. Read the installed workflow in existing sessions; refresh discovery if needed. Hooks and routines are not installed.\n", len(result.Skills), result.Directory)
			return err
		},
	}
	install.Flags().StringVar(&destination, "dir", "", "Skill discovery directory (default ~/.agents/skills)")
	cmd.AddCommand(install)
	return cmd
}

type skillInstallation struct {
	Directory string   `json:"directory"`
	Bundle    string   `json:"bundle"`
	Skills    []string `json:"skills"`
}

// The bundle is content addressed. Only links into verified bundles in our
// own data directory may be upgraded; manually installed skills stay untouched.
func installSkills(destination, cache string) (skillInstallation, error) {
	var result skillInstallation
	destination, err := filepath.Abs(destination)
	if err != nil {
		return result, err
	}
	cache, err = filepath.Abs(cache)
	if err != nil {
		return result, err
	}
	files := map[string][]byte{}
	entries, err := fs.ReadDir(payload.Skills, "skills")
	if err != nil {
		return result, err
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		result.Skills = append(result.Skills, name)
		body, err := fs.ReadFile(payload.Skills, "skills/"+name+"/SKILL.md")
		if err != nil {
			return result, err
		}
		body = []byte(strings.NewReplacer(
			"../../docs/api.md", "references/api.md",
			"../../docs/quota.md", "references/quota.md",
			"../../docs/participation.md", "references/participation.md",
			"../../docs/context.md", "references/context.md",
		).Replace(string(body)))
		if name == "agentboard-grok" {
			body = []byte(strings.ReplaceAll(string(body), "../../GROK_BOT.md", "references/GROK_BOT.md"))
			charter, err := fs.ReadFile(payload.Skills, "GROK_BOT.md")
			if err != nil {
				return result, err
			}
			// The installed charter lives one level under this skill; route its local
			// references through the sibling canonical and captain workflows.
			charterText := string(charter)
			charterText = strings.ReplaceAll(charterText, "(AGENTS.md)", "(https://github.com/carverauto/agentboard/blob/main/AGENTS.md)")
			charterText = strings.ReplaceAll(charterText, "(skills/", "(../../")
			charterText = strings.ReplaceAll(charterText, "(docs/quota.md)", "(../../agentboard/references/quota.md)")
			files["skills/"+name+"/references/GROK_BOT.md"] = []byte(charterText)
		}
		files["skills/"+name+"/SKILL.md"] = body
		if name == "agentboard" || name == "agentboard-captain" {
			for _, doc := range []string{"api.md", "quota.md", "participation.md", "context.md"} {
				body, err := fs.ReadFile(payload.Skills, "docs/"+doc)
				if err != nil {
					return result, err
				}
				files["skills/"+name+"/references/"+doc] = body
			}
		}
	}
	sort.Strings(result.Skills)
	digest := skillDigest(files)
	bundle := filepath.Join(cache, digest)
	result.Directory, result.Bundle = destination, bundle
	if err := os.MkdirAll(cache, 0755); err != nil {
		return result, err
	}
	// Serialize installers across discovery destinations. A crash leaves a visible
	// lock that must be inspected, never silently stolen by another invocation.
	lock := filepath.Join(cache, ".install-lock")
	if err := os.Mkdir(lock, 0700); err != nil {
		return result, fmt.Errorf("skill installer lock %s: %w (if left after a crash, inspect before removing)", lock, err)
	}
	defer os.Remove(lock)
	prior := map[string]string{}
	verified := map[string]bool{}
	for _, name := range result.Skills {
		target := filepath.Join(destination, name)
		info, err := os.Lstat(target)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return result, err
		}
		if info.Mode()&os.ModeSymlink == 0 {
			return result, fmt.Errorf("skill conflict at %s: preserve or move the existing installation", target)
		}
		link, err := os.Readlink(target)
		if err != nil {
			return result, err
		}
		if !filepath.IsAbs(link) {
			link = filepath.Join(destination, link)
		}
		link = filepath.Clean(link)
		relative, err := filepath.Rel(cache, link)
		parts := strings.Split(relative, string(filepath.Separator))
		if err != nil || len(parts) != 3 || parts[1] != "skills" || parts[2] != name || len(parts[0]) != 64 {
			return result, fmt.Errorf("skill conflict at %s: link is not managed by Agentboard", target)
		}
		old := filepath.Join(cache, parts[0])
		if !verified[old] {
			if err := verifySkillBundle(old, parts[0]); err != nil {
				return result, fmt.Errorf("preserving edited or invalid skill bundle: %w", err)
			}
			verified[old] = true
		}
		prior[name] = link
	}
	if _, err := os.Lstat(bundle); errors.Is(err, fs.ErrNotExist) {
		stage, err := os.MkdirTemp(cache, ".bundle-")
		if err != nil {
			return result, err
		}
		defer os.RemoveAll(stage)
		for name, body := range files {
			path := filepath.Join(stage, filepath.FromSlash(name))
			if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
				return result, err
			}
			if err := os.WriteFile(path, body, 0644); err != nil {
				return result, err
			}
		}
		if err := os.Rename(stage, bundle); err != nil {
			return result, err
		}
	} else if err != nil {
		return result, err
	}
	if err := verifySkillBundle(bundle, digest); err != nil {
		return result, err
	}
	if err := os.MkdirAll(destination, 0755); err != nil {
		return result, err
	}
	for _, name := range result.Skills {
		target := filepath.Join(destination, name)
		// Recheck after staging so intervening manual changes are not overwritten.
		current, err := os.Readlink(target)
		if err == nil {
			if !filepath.IsAbs(current) {
				current = filepath.Join(destination, current)
			}
			current = filepath.Clean(current)
		}
		if prior[name] == "" {
			if _, err := os.Lstat(target); !errors.Is(err, fs.ErrNotExist) {
				return result, fmt.Errorf("skill destination changed during installation: %s", target)
			}
		} else if err != nil || current != prior[name] {
			return result, fmt.Errorf("skill destination changed during installation: %s", target)
		}
		wanted := filepath.Join(bundle, "skills", name)
		if current == wanted {
			continue
		}
		temp, err := os.CreateTemp(destination, ".agentboard-link-")
		if err != nil {
			return result, err
		}
		path := temp.Name()
		if err := temp.Close(); err != nil {
			os.Remove(path)
			return result, err
		}
		os.Remove(path)
		if err := os.Symlink(wanted, path); err != nil {
			return result, err
		}
		if err := os.Rename(path, target); err != nil {
			os.Remove(path)
			return result, err
		}
	}
	return result, nil
}

func skillDigest(files map[string][]byte) string {
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	hash := sha256.New()
	for _, name := range names {
		hash.Write([]byte(name))
		hash.Write([]byte{0})
		hash.Write(files[name])
		hash.Write([]byte{0})
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func verifySkillBundle(root, digest string) error {
	files := map[string][]byte{}
	err := filepath.WalkDir(root, func(path string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if e.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("bundle contains a symlink: %s", path)
		}
		if e.IsDir() {
			return nil
		}
		if !e.Type().IsRegular() {
			return fmt.Errorf("bundle contains a non-regular file: %s", path)
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		files[filepath.ToSlash(relative)] = body
		return nil
	})
	if err != nil {
		return err
	}
	if skillDigest(files) != digest {
		return fmt.Errorf("bundle content differs from its digest: %s", root)
	}
	return nil
}
