package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"

	"github.com/gotd/td/tg"
)

// helperServer is the persistent worker used by the macOS app. It keeps one
// gotd client (and therefore one file-DC sub-connection pool) alive across
// chats, previews and downloads. Commands are newline-delimited tabs so the
// app can keep using ManagedProcess without a second protocol library.
type helperServer struct {
	ctx  context.Context
	api  *tg.Client
	out  sync.Mutex
	mu   sync.Mutex
	wg   sync.WaitGroup
	work map[string]context.CancelFunc
	// Cancellation can arrive before the goroutine that owns a request has
	// registered itself (the app sends CANCEL immediately after a superseded
	// preview). Remember those ids so the request never does unnecessary work.
	cancelled map[string]struct{}
}

func serveCommands(ctx context.Context, api *tg.Client) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	s := &helperServer{
		ctx:       ctx,
		api:       api,
		work:      make(map[string]context.CancelFunc),
		cancelled: make(map[string]struct{}),
	}
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) < 2 || strings.TrimSpace(parts[1]) == "" {
			s.result("", "ERR", "malformed command")
			continue
		}
		requestID := strings.TrimSpace(parts[1])
		switch parts[0] {
		case "CANCEL":
			s.cancel(requestID)
		case "QUIT":
			s.cancelAll()
			s.wg.Wait()
			return nil
		default:
			s.wg.Add(1)
			go func(parts []string) {
				defer s.wg.Done()
				s.execute(parts)
			}(parts)
		}
	}
	s.cancelAll()
	s.wg.Wait()
	return scanner.Err()
}

func (s *helperServer) execute(parts []string) {
	cmd := parts[0]
	requestID := strings.TrimSpace(parts[1])
	ctx, cancel := context.WithCancel(s.ctx)
	defer cancel()

	s.mu.Lock()
	if _, ok := s.cancelled[requestID]; ok {
		delete(s.cancelled, requestID)
		s.mu.Unlock()
		s.result(requestID, "ERR", "cancelled")
		return
	}
	s.work[requestID] = cancel
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.work, requestID)
		s.mu.Unlock()
	}()

	arg := func(i int) string {
		if i < len(parts) {
			return parts[i]
		}
		return ""
	}

	switch cmd {
	case "PING":
		s.result(requestID, "OK", "")

	case "CHATS":
		data, err := chatsData(ctx, s.api)
		if err != nil {
			s.failOrCancel(ctx, requestID, err)
			return
		}
		s.result(requestID, "OK", string(data))

	case "MESSAGES":
		limit := parseInt(arg(3), 100)
		data, err := messagesData(ctx, s.api, arg(2), limit)
		if err != nil {
			s.failOrCancel(ctx, requestID, err)
			return
		}
		s.result(requestID, "OK", string(data))

	case "DOWNLOAD":
		if len(parts) < 6 {
			s.fail(requestID, fmt.Errorf("DOWNLOAD requires peer, message, output and threads"))
			return
		}
		messageID := parseInt(arg(3), 0)
		if messageID == 0 {
			s.fail(requestID, fmt.Errorf("invalid message id"))
			return
		}
		threads := parseInt(arg(5), 4)
		outcome, err := downloadMessage(ctx, s.api, arg(2), messageID, arg(4), threads,
			func(written, total int64) {
				s.out.Lock()
				fmt.Fprintf(os.Stdout, "PROGRESS\t%s\t%d\t%d\n", requestID, written, total)
				s.out.Unlock()
			})
		if err != nil {
			s.failOrCancel(ctx, requestID, err)
			return
		}
		s.result(requestID, "OK", fmt.Sprintf("%d\t%s", outcome.size, outcome.sha))

	case "WARM":
		messageID := parseInt(arg(3), 0)
		if messageID == 0 {
			s.fail(requestID, fmt.Errorf("invalid message id"))
			return
		}
		if err := warmMessage(ctx, s.api, arg(2), messageID); err != nil {
			s.failOrCancel(ctx, requestID, err)
			return
		}
		s.result(requestID, "OK", "")

	case "WARM_PEER":
		count, err := warmPeer(ctx, s.api, arg(2), parseInt(arg(3), 100))
		if err != nil {
			s.failOrCancel(ctx, requestID, err)
			return
		}
		s.result(requestID, "OK", strconv.Itoa(count))

	default:
		s.fail(requestID, fmt.Errorf("unknown command %q", cmd))
	}
}

func (s *helperServer) result(requestID, status, payload string) {
	s.out.Lock()
	defer s.out.Unlock()
	if payload == "" {
		fmt.Fprintf(os.Stdout, "RESULT\t%s\t%s\n", requestID, status)
		return
	}
	fmt.Fprintf(os.Stdout, "RESULT\t%s\t%s\t%s\n", requestID, status, payload)
}

func (s *helperServer) fail(requestID string, err error) {
	message := strings.NewReplacer("\t", " ", "\r", " ", "\n", " ").Replace(err.Error())
	s.result(requestID, "ERR", message)
}

// failOrCancel keeps an in-flight preview cancellation out of the user's
// error card. The app cancels a download by closing the viewer; the context
// error is expected in that case, not a Telegram failure.
func (s *helperServer) failOrCancel(ctx context.Context, requestID string, err error) {
	if ctx.Err() != nil {
		s.result(requestID, "ERR", "cancelled")
		return
	}
	s.fail(requestID, err)
}

func (s *helperServer) cancel(requestID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if cancel, ok := s.work[requestID]; ok {
		cancel()
		return
	}
	s.cancelled[requestID] = struct{}{}
}

func (s *helperServer) cancelAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, cancel := range s.work {
		cancel()
	}
}

func parseInt(raw string, fallback int) int {
	value, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return fallback
	}
	return value
}

// warmMessage opens a file-DC sub-connection with a 4 KiB read. It is a
// warm-up, not a preview: the bytes are discarded and nothing is written.
func warmMessage(ctx context.Context, api *tg.Client, peer string, messageID int) error {
	inputPeer, _, err := resolveInputPeer(ctx, api, peer)
	if err != nil {
		return err
	}
	msg, err := fetchMessageFromPeer(ctx, api, inputPeer, messageID)
	if err != nil {
		return err
	}
	loc, _, _, err := downloadLocation(msg)
	if err != nil {
		return err
	}
	_, err = api.UploadGetFile(ctx, &tg.UploadGetFileRequest{
		Offset:   0,
		Limit:    4096,
		Location: loc,
	})
	return err
}

// warmPeer warms one representative file per datacenter used by the recent
// media in a chat. A channel usually keeps its videos on one file DC, while
// photos may use another; two small reads cover both without downloading any
// visible media.
func warmPeer(ctx context.Context, api *tg.Client, peer string, limit int) (int, error) {
	inputPeer, _, err := resolveInputPeer(ctx, api, peer)
	if err != nil {
		return 0, err
	}
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	result, err := api.MessagesGetHistory(ctx, &tg.MessagesGetHistoryRequest{
		Peer:  inputPeer,
		Limit: limit,
	})
	if err != nil {
		return 0, fmt.Errorf("get history for warm-up: %w", err)
	}

	seen := make(map[int]bool)
	count := 0
	for _, raw := range messageList(result) {
		msg, ok := raw.(*tg.Message)
		if !ok {
			continue
		}
		dc := mediaDC(msg)
		if dc == 0 || seen[dc] {
			continue
		}
		loc, _, _, err := downloadLocation(msg)
		if err != nil {
			continue
		}
		if _, err := api.UploadGetFile(ctx, &tg.UploadGetFileRequest{
			Offset:   0,
			Limit:    4096,
			Location: loc,
		}); err != nil {
			// Do not mark this DC as warmed on a failed read; another file
			// on the same DC may still succeed.
			continue
		}
		seen[dc] = true
		count++
	}
	return count, nil
}

func mediaDC(msg *tg.Message) int {
	switch media := msg.Media.(type) {
	case *tg.MessageMediaDocument:
		if media.Document == nil {
			return 0
		}
		if doc, ok := media.Document.AsNotEmpty(); ok {
			return doc.DCID
		}
	case *tg.MessageMediaPhoto:
		if media.Photo == nil {
			return 0
		}
		if photo, ok := media.Photo.AsNotEmpty(); ok {
			return photo.DCID
		}
	}
	return 0
}
