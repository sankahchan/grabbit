package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"mime"
	"os"
	"path/filepath"
	"strings"

	"github.com/gotd/td/telegram"
	"github.com/gotd/td/telegram/message"
	"github.com/gotd/td/tg"
)

// runSelfUpload leaves one test document in Saved Messages so the UI preview
// and download paths can be exercised end-to-end. Pass -file to upload a real
// image/video/audio file; without it a generated 4 KB blob is used. The
// document carries its real filename and MIME type either way, which is what
// the preview classifier in the app keys off.
func runSelfUpload(ctx context.Context, client *telegram.Client, filePath string) error {
	api := client.API()

	srcPath := filePath
	cleanup := func() {}
	if srcPath == "" {
		dir, err := os.MkdirTemp("", "grabbit-telegram-ui-test-")
		if err != nil {
			return fmt.Errorf("create temp directory: %w", err)
		}
		cleanup = func() { os.RemoveAll(dir) }
		srcPath = filepath.Join(dir, "grabbit-telegram-ui-test.bin")
		data := make([]byte, 4096)
		for i := range data {
			data[i] = byte((i*53 + 29) % 256)
		}
		if err := os.WriteFile(srcPath, data, 0600); err != nil {
			cleanup()
			return fmt.Errorf("write test file: %w", err)
		}
	} else {
		absolute, err := filepath.Abs(srcPath)
		if err != nil {
			return fmt.Errorf("resolve upload file: %w", err)
		}
		info, err := os.Stat(absolute)
		if err != nil {
			return fmt.Errorf("open upload file: %w", err)
		}
		if info.IsDir() {
			return fmt.Errorf("upload file %q is a directory", absolute)
		}
		srcPath = absolute
	}
	defer cleanup()

	sum, err := hashFile(srcPath)
	if err != nil {
		return err
	}

	filename := filepath.Base(srcPath)
	mimeType := mime.TypeByExtension(strings.ToLower(filepath.Ext(filename)))
	if mimeType == "" {
		mimeType = "application/octet-stream"
	}

	sender := message.NewSender(api).Self()
	input, err := sender.Upload(message.FromPath(srcPath)).AsInputFile(ctx)
	if err != nil {
		return fmt.Errorf("upload %s to Saved Messages: %w", filename, err)
	}
	updates, err := sender.Media(ctx, message.UploadedDocument(input).
		MIME(mimeType).
		Filename(filename).
		ForceFile(true))
	if err != nil {
		return fmt.Errorf("send %s to Saved Messages: %w", filename, err)
	}
	msg, err := messageFromUpdates(ctx, api, updates)
	if err != nil {
		return err
	}
	doc, err := documentFromMessage(msg)
	if err != nil {
		return err
	}
	fmt.Printf("SELF_UPLOADED\tmessage=%d\tdocument=%d\tsize=%d\tsha256=%s\tname=%s\tmime=%s\n",
		msg.ID, doc.GetID(), doc.GetSize(), sum, filename, mimeType)
	return nil
}

func hashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open %s for hashing: %w", path, err)
	}
	defer file.Close()

	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", fmt.Errorf("hash %s: %w", path, err)
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func deleteMessage(ctx context.Context, api *tg.Client, peer string, messageID int) error {
	if messageID == 0 {
		return fmt.Errorf("-delete requires -message")
	}
	inputPeer, title, err := resolveInputPeer(ctx, api, peer)
	if err != nil {
		return err
	}
	switch p := inputPeer.(type) {
	case *tg.InputPeerChannel:
		_, err = api.ChannelsDeleteMessages(ctx, &tg.ChannelsDeleteMessagesRequest{
			Channel: &tg.InputChannel{ChannelID: p.ChannelID, AccessHash: p.AccessHash},
			ID:      []int{messageID},
		})
	default:
		_, err = api.MessagesDeleteMessages(ctx, &tg.MessagesDeleteMessagesRequest{
			Revoke: true,
			ID:     []int{messageID},
		})
	}
	if err != nil {
		return fmt.Errorf("delete message %d from %s: %w", messageID, title, err)
	}
	fmt.Printf("DELETE_OK\t%d\n", messageID)
	return nil
}
