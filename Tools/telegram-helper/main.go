// Command grabbit-telegram-helper owns Grabbit's Telegram MTProto session and
// exposes line-oriented commands to the macOS app. It is a separate process so
// the account session never lives in Grabbit's address space.
//
// The binary is built by scripts/vendor-telegram-helper.sh and bundled at
// Grabbit.app/Contents/Resources/bin/grabbit-telegram-helper.
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/gotd/td/session"
	"github.com/gotd/td/telegram"
	"github.com/gotd/td/telegram/auth"
	"github.com/gotd/td/telegram/auth/qrlogin"
	"github.com/gotd/td/tg"
	"github.com/gotd/td/tgerr"
)

// Release builds inject app-level credentials with -ldflags "-X main.defaultAPIID=... -X main.defaultAPIHash=...".
// Users never see or enter these values; local development still uses
// ~/.config/grabbit/telegram.env or GRABBIT_TELEGRAM_ENV.
var (
	defaultAPIID   string
	defaultAPIHash string
	processStart   = time.Now()
)

func timing(name string) {
	if os.Getenv("GRABBIT_TIMING") == "" {
		return
	}
	fmt.Fprintf(os.Stderr, "TIMING\t%s\t%.0fms\n", name, time.Since(processStart).Seconds()*1000)
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	selfTest := flag.Bool("self-test", false, "upload a small test file to Saved Messages, download it, and verify its checksum")
	selfUpload := flag.Bool("self-upload", false, "upload a test file to Saved Messages and leave it for a UI test")
	selfUploadFile := flag.String("file", "", "optional file to upload with -self-upload (default: generated 4 KB test blob)")
	deleteMode := flag.Bool("delete", false, "delete one message")
	statusMode := flag.Bool("status", false, "print AUTHORIZED or UNAUTHORIZED and exit")
	logoutMode := flag.Bool("logout", false, "log out the current Telegram session and exit")
	loginMode := flag.Bool("login", false, "run QR login and exit after authorization")
	serveMode := flag.Bool("serve", false, "run a persistent command server for the macOS app")
	chatsMode := flag.Bool("chats", false, "print the chat list as JSON and exit")
	messagesPeer := flag.String("messages", "", "print recent media messages for this peer as JSON and exit")
	downloadMode := flag.Bool("download", false, "download one message attachment")
	peer := flag.String("peer", "", "peer for -messages/-download (username or numeric id)")
	messageID := flag.Int("message", 0, "message id for -download")
	outPath := flag.String("out", "", "output file path for -download")
	downloadThreads := flag.Int("threads", 4, "parallel download connections (1-8)")
	limit := flag.Int("limit", 50, "maximum messages to return")
	passwordFlag := flag.String("password", "", "two-step verification password")
	flag.Parse()

	env, err := loadEnv(os.Getenv("GRABBIT_TELEGRAM_ENV"))
	if err != nil {
		return err
	}

	apiID := 0
	if rawID := strings.TrimSpace(env["TELEGRAM_API_ID"]); rawID != "" {
		parsed, err := strconv.Atoi(rawID)
		if err != nil || parsed == 0 {
			return fmt.Errorf("TELEGRAM_API_ID is invalid")
		}
		apiID = parsed
	}
	if apiID == 0 {
		if rawID := strings.TrimSpace(defaultAPIID); rawID != "" {
			parsed, err := strconv.Atoi(rawID)
			if err != nil || parsed == 0 {
				return fmt.Errorf("embedded TELEGRAM_API_ID is invalid")
			}
			apiID = parsed
		}
	}
	apiHash := strings.TrimSpace(env["TELEGRAM_API_HASH"])
	if apiHash == "" {
		apiHash = strings.TrimSpace(defaultAPIHash)
	}
	if apiID == 0 || apiHash == "" {
		return fmt.Errorf("Telegram credentials are not configured")
	}

	sessionPath, err := sessionFile(env)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(sessionPath), 0700); err != nil {
		return fmt.Errorf("create session directory: %w", err)
	}

	var ctx context.Context
	var cancel context.CancelFunc
	if *serveMode {
		// The worker is intentionally long-lived: keeping the MTProto client
		// and its file-DC sub-connections alive removes the per-download
		// handshake from the user's critical path.
		ctx, cancel = context.WithCancel(context.Background())
	} else {
		ctx, cancel = context.WithTimeout(context.Background(), 10*time.Minute)
	}
	defer cancel()

	timing("config-ready")
	dispatcher := tg.NewUpdateDispatcher()
	loggedIn := qrlogin.OnLoginToken(dispatcher)
	client := telegram.NewClient(apiID, apiHash, telegram.Options{
		SessionStorage: &session.FileStorage{Path: sessionPath},
		UpdateHandler:  dispatcher,
	})

	return client.Run(ctx, func(ctx context.Context) error {
		timing("client-connected")
		// Downloads do not need auth-status or self RPCs: the session file
		// already proves authorization, and an invalid session surfaces on
		// the first file request. Skipping those round trips shaves roughly
		// half a second from the pre-download delay.
		if *downloadMode {
			return outputDownload(ctx, client.API(), *peer, *messageID, *outPath, *downloadThreads)
		}
		if *serveMode {
			status, err := client.Auth().Status(ctx)
			if err != nil {
				return fmt.Errorf("auth status: %w", err)
			}
			if !status.Authorized {
				return fmt.Errorf("Telegram session is not authorized; connect first")
			}
			timing("worker-ready")
			fmt.Println("READY")
			return serveCommands(ctx, client.API())
		}
		status, err := client.Auth().Status(ctx)
		if err != nil {
			return fmt.Errorf("auth status: %w", err)
		}
		timing("auth-status")
		if *statusMode {
			if status.Authorized {
				fmt.Println("AUTHORIZED")
			} else {
				fmt.Println("UNAUTHORIZED")
			}
			return nil
		}
		if *logoutMode {
			if status.Authorized {
				if _, err := client.API().AuthLogOut(ctx); err != nil {
					return fmt.Errorf("log out: %w", err)
				}
			}
			fmt.Println("LOGOUT_OK")
			return nil
		}

		// Machine commands must never silently fall into the interactive QR
		// loop. Without a session they would print a QR URL to a caller that
		// does not render it and then wait until the context expires.
		if !status.Authorized &&
			(*chatsMode || *messagesPeer != "" || *deleteMode || *selfTest || *selfUpload) {
			return fmt.Errorf("Telegram session is not authorized; connect first")
		}

		if !status.Authorized {
			fmt.Println("AUTH_STATE=WAITING_FOR_QR")
			_, err = client.QR().Auth(ctx, loggedIn, func(_ context.Context, token qrlogin.Token) error {
				fmt.Printf("QR_URL=%s\n", token.URL())
				return nil
			})
			if err != nil {
				if !tgerr.Is(err, "SESSION_PASSWORD_NEEDED") {
					return fmt.Errorf("QR login: %w", err)
				}
				password := configuredPassword(*passwordFlag, env)
				if password == "" {
					for {
						fmt.Println("NEED_2FA=1")
						password, err = readPasswordLine(ctx)
						if err != nil {
							return fmt.Errorf("read two-step password: %w", err)
						}
						if password == "" {
							continue
						}
						if _, err := client.Auth().Password(ctx, password); err != nil {
							// gotd returns a sentinel for a wrong password,
							// not a tgerr; matching the RPC string here made
							// the helper exit and lose the QR-approved key.
							if errors.Is(err, auth.ErrPasswordInvalid) {
								continue
							}
							return fmt.Errorf("two-step verification: %w", err)
						}
						break
					}
				} else if _, err := client.Auth().Password(ctx, password); err != nil {
					return fmt.Errorf("two-step verification: %w", err)
				}
			}
		}

		me, err := client.Self(ctx)
		if err != nil {
			return fmt.Errorf("get self: %w", err)
		}
		timing("self")
		machineMode := *chatsMode || *messagesPeer != ""
		if !machineMode {
			fmt.Printf("AUTH_STATE=AUTHORIZED\n")
			fmt.Printf("SELF\t%d\t%s\t%s\n", me.ID, displayName(me.FirstName, me.LastName), me.Username)
		}

		switch {
		case *loginMode:
			fmt.Println("AUTH_OK")
			return nil
		case *selfTest:
			return runSelfTest(ctx, client)
		case *selfUpload:
			return runSelfUpload(ctx, client, *selfUploadFile)
		case *deleteMode:
			return deleteMessage(ctx, client.API(), *peer, *messageID)
		case *chatsMode:
			return outputChats(ctx, client.API())
		case *messagesPeer != "":
			return outputMessages(ctx, client.API(), *messagesPeer, *limit)
		default:
			return listDialogs(ctx, client.API())
		}
	})
}

func listDialogs(ctx context.Context, api *tg.Client) error {
	result, err := api.MessagesGetDialogs(ctx, &tg.MessagesGetDialogsRequest{
		Limit:      50,
		OffsetPeer: &tg.InputPeerEmpty{},
	})
	if err != nil {
		return fmt.Errorf("get dialogs: %w", err)
	}
	dialogs, ok := result.AsModified()
	if !ok {
		return fmt.Errorf("unexpected dialogs result %T", result)
	}

	users := make(map[int64]*tg.User)
	for _, raw := range dialogs.GetUsers() {
		if user, ok := raw.(*tg.User); ok {
			users[user.ID] = user
		}
	}
	chats := make(map[int64]*tg.Chat)
	channels := make(map[int64]*tg.Channel)
	for _, raw := range dialogs.GetChats() {
		switch chat := raw.(type) {
		case *tg.Chat:
			chats[chat.ID] = chat
		case *tg.Channel:
			channels[chat.ID] = chat
		}
	}

	fmt.Println("DIALOGS_BEGIN")
	count := 0
	for _, raw := range dialogs.GetDialogs() {
		dialog, ok := raw.(*tg.Dialog)
		if !ok {
			continue
		}
		kind, id, title, username := peerInfo(dialog.Peer, users, chats, channels)
		if title == "" {
			continue
		}
		fmt.Printf("DIALOG\t%s\t%d\t%s\t%s\n", kind, id, title, username)
		count++
	}
	fmt.Printf("DIALOGS_END\t%d\n", count)
	return nil
}

func peerInfo(peer tg.PeerClass, users map[int64]*tg.User, chats map[int64]*tg.Chat, channels map[int64]*tg.Channel) (kind string, id int64, title, username string) {
	switch p := peer.(type) {
	case *tg.PeerUser:
		user := users[p.UserID]
		if user == nil {
			return "user", p.UserID, "", ""
		}
		return "user", user.ID, displayName(user.FirstName, user.LastName), user.Username
	case *tg.PeerChat:
		chat := chats[p.ChatID]
		if chat == nil {
			return "group", p.ChatID, "", ""
		}
		return "group", chat.ID, chat.Title, ""
	case *tg.PeerChannel:
		channel := channels[p.ChannelID]
		if channel == nil {
			return "channel", p.ChannelID, "", ""
		}
		return "channel", channel.ID, channel.Title, channel.Username
	default:
		return "unknown", 0, "", ""
	}
}

func displayName(first, last string) string {
	name := strings.TrimSpace(first + " " + last)
	if name == "" {
		return "(no name)"
	}
	return name
}

func configuredPassword(flagValue string, env map[string]string) string {
	if flagValue != "" {
		return flagValue
	}
	if value := os.Getenv("TELEGRAM_2FA_PASSWORD"); value != "" {
		return value
	}
	return env["TELEGRAM_2FA_PASSWORD"]
}

// readPasswordLine waits for one line from the app over stdin. Keeping the
// helper process alive after the QR scan lets us use the same auth key for
// auth.checkPassword; restarting it would invalidate the login token and show
// another QR code.
func readPasswordLine(ctx context.Context) (string, error) {
	type result struct {
		line string
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		scanner := bufio.NewScanner(os.Stdin)
		if scanner.Scan() {
			ch <- result{line: scanner.Text()}
			return
		}
		err := scanner.Err()
		if err == nil {
			err = fmt.Errorf("password input closed")
		}
		ch <- result{err: err}
	}()

	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case r := <-ch:
		return r.line, r.err
	}
}

func loadEnv(path string) (map[string]string, error) {
	if path == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		path = filepath.Join(home, ".config", "grabbit", "telegram.env")
	}
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]string{}, nil
		}
		return nil, fmt.Errorf("open Telegram config: %w", err)
	}
	defer file.Close()

	values := make(map[string]string)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		value = strings.Trim(value, `"'`)
		values[strings.TrimSpace(key)] = value
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read Telegram config: %w", err)
	}
	return values, nil
}

func sessionFile(env map[string]string) (string, error) {
	if path := strings.TrimSpace(env["TELEGRAM_SESSION_FILE"]); path != "" {
		return path, nil
	}
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("find application support directory: %w", err)
	}
	return filepath.Join(configDir, "Grabbit", "Telegram", "session.json"), nil
}
